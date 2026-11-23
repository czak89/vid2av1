# vid2av1

A PowerShell script that batch-converts a video library to **AV1** using NVIDIA's hardware encoder (`av1_nvenc`). It was written for an RTX 5090 and works on any NVENC GPU that supports AV1 (RTX 40-series and newer).

It runs unattended. An original is replaced **only if the new file is valid AV1, has the same length and is smaller**. Otherwise the original is kept.

> Console output, the help text and the CSV log are in Polish.

## Features

- **Folders:** goes through a folder and its subfolders.
- **Skips:** files that are already AV1 or HEVC.
- **Bitrate:** picks a target based on resolution and source bitrate, never below 25% of the source bitrate.
- **Audio:** keeps **all audio tracks**. Tracks are copied unchanged when MP4 supports their codec; otherwise they are converted to AAC with the same number of channels.
- **Checks before replacing:** the output must fully decode without errors, its length must match the source (±0.5 s by default), and it must be smaller.
- **Safe disposal of originals:** they go to the Recycle Bin, to an archive folder, or are deleted for good if you ask for that. Files that Windows would silently delete instead of recycling are skipped before encoding: files on network or USB drives, or files bigger than the Recycle Bin limit.
- **Dry run** with `-WhatIf`, and a per-file prompt with `-Confirm`.
- **Progress:** overall and per-file progress bars with time remaining.
- **Summary and log:** a summary at the end, plus a CSV log that opens correctly in Excel.
- **GPU check at startup**, so a missing driver or GPU fails immediately instead of on every file.

## Requirements

- Windows with PowerShell 7+ (recommended) or Windows PowerShell 5.1
- An NVIDIA GPU with AV1 NVENC and a current driver
- `ffmpeg` and `ffprobe` on `PATH`, built with CUDA and NVENC support (e.g. the gyan.dev or BtbN builds)

## Usage

```powershell
# See what would happen. Nothing is encoded, moved or deleted.
.\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Videos -WhatIf

# Convert everything; originals go to the Recycle Bin
.\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Videos

# Keep originals in a separate folder (subfolder structure is mirrored)
.\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Videos -ArchivePath E:\Originals

# Delete originals permanently (required for network/USB drives unless -ArchivePath is used)
.\ffmpeg-vid2av1-minimum-25.ps1 -Path \\nas\videos -PermanentDelete

# Ask before each file
.\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Videos -Confirm
```

Full help: `Get-Help .\ffmpeg-vid2av1-minimum-25.ps1 -Full`

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Path` | current folder | Folder to process |
| `-NoRecurse` | off | Don't look in subfolders |
| `-Extensions` | `mp4 mkv mov avi ts m4v webm wmv` | File types to process |
| `-Preset` | `p4` | NVENC preset, `p1` (fastest) to `p7` (best quality) |
| `-DurationTolerance` | `0.5` | Allowed length difference in seconds |
| `-ArchivePath` | – | Move originals here instead of the Recycle Bin |
| `-PermanentDelete` | off | Delete originals permanently |
| `-LogPath` | `<Path>\vid2av1-<timestamp>.csv` | Location of the CSV log |
| `-NoLog` | off | Don't write a CSV log |
| `-SkipGpuCheck` | off | Skip the startup NVENC test |
| `-TempDir` | `<Path>\av1_nvenc` | Folder for in-progress encodes |
| `-WhatIf` / `-Confirm` | – | Dry run / ask before each file |

## How it works

1. **Scan:** collects the video files once, before any encoding starts, so the new `.mp4` files are never processed again in the same run.
2. **Analyze:** reads each file once with `ffprobe` and decides whether to skip it. A file is skipped if:
   - it is already AV1 or HEVC;
   - it can't be read;
   - the target `.mp4` name is already taken by another file;
   - its original couldn't be safely recycled.
3. **Encode:** runs `av1_nvenc` in VBR mode at the target bitrate, with CUDA decoding.
   - Output is always `.mp4`, written next to the source as `<name>.mp4`.
   - Subtitle tracks are **not** kept.
4. **Verify:** checks the codec, fully decodes the output to catch errors, compares its length with the source, and compares sizes.
5. **Replace:**
   1. The new file is moved next to the original.
   2. The original is recycled, archived or deleted.
   3. If that step fails, the new file is removed and the original stays where it was.

Pressing **Ctrl+C** stops the run cleanly. The partial encode is deleted, the original is untouched, and the file is logged as interrupted.

## Output

- A summary at the end lists:
  - how many files were converted, rejected, failed or skipped;
  - the total space saved;
  - the files whose original was kept, and why.
- The CSV log gets one row per file: status, reason, codec, resolution, bitrates, lengths, sizes, space saved, encode time, and where the original went.

## ⚠️ Caution

This tool removes original files. Before pointing it at a library you care about:

1. Run it with `-WhatIf`.
2. Try it on a folder of **copies**.
3. Spot-check a few results for quality.

The bitrate rules favour space savings, so results can look visibly worse than the original for some content.

## License

[MIT](LICENSE)
