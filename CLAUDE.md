# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single PowerShell script, `ffmpeg-vid2av1-minimum-25.ps1`, that batch-converts videos to AV1 with NVIDIA NVENC (`av1_nvenc`, targeted at an RTX 5090). It runs unattended and replaces each original once the AV1 result passes validation, has the same length and is smaller. There is no build system, no tests and no linter. Full parameter help: `Get-Help .\ffmpeg-vid2av1-minimum-25.ps1 -Full`.

## Running

```powershell
.\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Videos -WhatIf                     # dry run: plan table, nothing written
.\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Videos                             # originals -> Recycle Bin
.\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Videos -ArchivePath E:\Originals   # originals moved, folder structure mirrored
.\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Videos -PermanentDelete
.\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Videos -Confirm                    # ask before each file
```

Other parameters:
- `-NoRecurse`, `-Extensions mkv,avi`
- `-Preset p1..p7` (default p4)
- `-DurationTolerance` (seconds, default 0.5)
- `-LogPath`, `-NoLog`, `-SkipGpuCheck`, `-TempDir`

Requirements and side effects:
- `ffmpeg` and `ffprobe` must be on PATH, and the ffmpeg build must support CUDA and `av1_nvenc`.
- Each run writes a CSV log to `<Path>\vid2av1-<timestamp>.csv`. It uses `-UseCulture`, so the separator and decimal mark follow the system locale (Excel-friendly). It is written as UTF-8 with BOM, and one row is appended per file as it finishes, so interrupted runs still leave a log.

**Testing:** `ffmpeg` may not be available in the dev environment. The script's logic can be tested end-to-end by putting stub `ffmpeg.cmd`/`ffprobe.cmd` on PATH:
- `ffprobe` returns canned `-of json` output.
- `ffmpeg` writes `out_time_us=` lines and creates the output file when it sees `-progress`.
- Note that a `.ps1` stub launched via `pwsh -File` mangles args like `-c:v`.

Use `-ArchivePath` in tests so nothing lands in the real Recycle Bin. Never test on real videos without copies.

## Flow

1. **Settings and preflight:**
   - Resolve paths and print a settings header.
   - Check that `ffmpeg`/`ffprobe` are on PATH.
   - GPU check (`Test-NvencAvailable`): encodes 1 s of `testsrc2` with `-init_hw_device cuda` + `av1_nvenc` to `-f null`. It exits 1 on failure; under `-WhatIf` it only warns.
2. **Scan:**
   - One `Get-ChildItem` pass, with exact extension matching (avoids 8.3 short-name false matches).
   - Excludes the temp dir, the archive dir and staged `*.vid2av1-xxxxxxxx.tmp.mp4` files.
   - The list is built up front, so the `.mp4` files created during the run are never re-processed.
3. **Analyze and plan:**
   - `Get-VideoInfo` makes one `ffprobe -of json` call per file to get codec, size, bitrate (stream with format fallback), duration and the audio streams.
   - Files are skipped *before* encoding if:
     - the video stream is unreadable;
     - the codec is already `av1`/`hevc`;
     - a different `<base>.mp4` already exists;
     - in Recycle mode, the Recycle Bin can't take the file.
   - `Get-RecycleBinLimitBytes` decides that last case:
     - It returns 0 unless the drive is fixed, or if `NukeOnDelete` is set.
     - Otherwise it reads `MaxCapacity` from `HKCU\...\Explorer\BitBucket\Volume\{guid}`, or assumes 5% of the drive.
     - This matters because Windows silently deletes files permanently when they exceed the cap.
   - `-WhatIf` prints the plan and skip tables here and exits 0.
4. **Encode** (`Invoke-Av1Encode`), one attempt per file:
   - Bitrate:
     - Target from `Get-TargetBitrateKbps`: resolution class × source-bitrate tier, factor floored at **0.25** (the "minimum-25" in the name), at least 300 kb/s, with fixed defaults when the bitrate is unknown.
     - VBR, maxrate 1.3×, bufsize 3×, spatial/temporal AQ, lookahead 48, 7 B-frames.
   - Streams:
     - Maps the first video stream and **all** audio streams. Subtitles and data streams are dropped.
     - `Get-AudioCodecArgs` stream-copies MP4-compatible audio (aac, mp3, mp2, ac3, eac3, opus, flac, alac). Anything else becomes AAC with its channel count kept: 192k for up to 2 channels, 384k for more.
   - ffmpeg runs with `-hide_banner -nostdin -loglevel warning -nostats -progress pipe:1`. The stdout lines are parsed for `out_time_us`/`speed` to drive `Write-RunProgress`, which shows an overall bar (ETA from processed media seconds vs. total planned duration) and a per-file bar.
5. **Accept or reject:**
   - The encode wins only if all three checks pass:
     - it is valid AV1 (ffprobe codec check plus a full `ffmpeg -xerror -f null` decode);
     - its duration is within `-DurationTolerance`;
     - it is smaller than the source.
   - Otherwise the status is `Odrzucono` and the original is kept.
6. **Install** (`Install-EncodedFile`):
   1. Stage the encode next to the source. When the source is already `.mp4`, it goes under a temporary `.vid2av1-xxxxxxxx.tmp.mp4` name.
   2. Dispose of the original via `Remove-OriginalFile`: Recycle (`Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile`), Archive (move to the mirrored relative path, adding a GUID suffix on collision) or Delete. If this fails, the staged file is removed and the original stays.
   3. Rename the staged file to `<base>.mp4`.
7. **Bookkeeping:**
   - Per-file `try/finally` deletes the temp encode and logs the record, so Ctrl+C still leaves a row with status `Przerwano`.
   - An outer `finally` clears the progress bars, removes the temp dir if this run created it and it is empty, and prints `Write-Summary`:
     - counts per status;
     - space saved;
     - a table of rejected, failed and interrupted files;
     - skip reasons grouped.

Result records come from `New-ResultRecord`. The Polish column names also become the CSV header. Status values are `Skonwertowano`, `Odrzucono`, `Blad`, `Przerwano` and `Pominieto`.

## Conventions

- Console messages, comments, help text and CSV columns are in **Polish, written without diacritics** (e.g. `Kodowanie nie powiodlo sie`). Keep new text in the same style.
- Use `-LiteralPath` for every file operation, because filenames may contain `[` and `]`. Create directories with `[System.IO.Directory]::CreateDirectory`.
- The script declares `SupportsShouldProcess`, and `-Confirm` lowers `$ConfirmPreference`, so every internal `Move-Item`, `Remove-Item` and `Export-Csv` passes `-Confirm:$false`. Otherwise `-Confirm` would prompt for each internal step as well as for each file.
- The script stays compatible with Windows PowerShell 5.1. Version-specific behaviour is gated on `$PSVersionTable.PSVersion.Major`, as with the CSV encoding and `-NoTypeInformation`.
