<#
.SYNOPSIS
    Batch konwersja wideo -> AV1 (NVENC) dla RTX 5090.

.DESCRIPTION
    Przeszukuje folder (domyslnie z podfolderami), koduje kazdy plik wideo do AV1
    przez av1_nvenc i zastepuje oryginal tylko wtedy, gdy wynik:
      - jest poprawnym plikiem AV1 (pelne dekodowanie bez bledow),
      - ma te sama dlugosc co zrodlo (w granicach -DurationTolerance),
      - jest mniejszy od zrodla.
    Pliki juz w AV1/HEVC sa pomijane. Wszystkie sciezki audio sa zachowane:
    kodeki obslugiwane przez MP4 sa kopiowane, pozostale kodowane do AAC.

    Oryginaly trafiaja do Kosza (domyslnie), do folderu -ArchivePath albo sa
    usuwane na stale (-PermanentDelete). Pliki, ktorych Kosz nie przyjmie
    (dysk sieciowy/USB, plik wiekszy niz limit Kosza), sa pomijane przed
    kodowaniem, zeby nigdy nie zostaly usuniete bez mozliwosci odzyskania.

    Kazde uruchomienie zapisuje log CSV i konczy sie podsumowaniem.

.PARAMETER Path
    Folder z plikami wideo. Domyslnie biezacy folder.

.PARAMETER NoRecurse
    Nie przeszukuj podfolderow.

.PARAMETER Extensions
    Rozszerzenia do przetworzenia (z kropka lub bez, np. mkv, .avi, *.mp4).

.PARAMETER Preset
    Preset av1_nvenc: p1 (najszybszy) .. p7 (najlepsza jakosc). Domyslnie p4.

.PARAMETER DurationTolerance
    Dopuszczalna roznica dlugosci zrodla i wyniku w sekundach. Domyslnie 0.5.

.PARAMETER ArchivePath
    Zamiast do Kosza, przenos oryginaly do tego folderu (z zachowaniem
    struktury podfolderow).

.PARAMETER PermanentDelete
    Usuwaj oryginaly na stale (bez Kosza).

.PARAMETER LogPath
    Sciezka logu CSV. Domyslnie <Path>\vid2av1-<data>-<czas>.csv.

.PARAMETER NoLog
    Nie zapisuj logu CSV.

.PARAMETER SkipGpuCheck
    Pomin test av1_nvenc na starcie.

.PARAMETER TempDir
    Folder na tymczasowe wyniki. Domyslnie <Path>\av1_nvenc.

.EXAMPLE
    .\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Wideo -WhatIf
    Pokazuje, co zostaloby zrobione, bez kodowania i usuwania czegokolwiek.

.EXAMPLE
    .\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Wideo -ArchivePath E:\Oryginaly
    Koduje wszystko w D:\Wideo, a oryginaly przenosi do E:\Oryginaly.

.EXAMPLE
    .\ffmpeg-vid2av1-minimum-25.ps1 -Path D:\Wideo -Confirm
    Pyta przed kodowaniem kazdego pliku.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [Parameter(Position = 0)]
    [string]$Path = ".",

    [switch]$NoRecurse,

    [string[]]$Extensions = @("mp4", "mkv", "mov", "avi", "ts", "m4v", "webm", "wmv"),

    [ValidateSet("p1", "p2", "p3", "p4", "p5", "p6", "p7")]
    [string]$Preset = "p4",

    [ValidateRange(0.0, 60.0)]
    [double]$DurationTolerance = 0.5,

    [string]$ArchivePath,

    [switch]$PermanentDelete,

    [string]$LogPath,

    [switch]$NoLog,

    [switch]$SkipGpuCheck,

    [string]$TempDir
)

$ErrorActionPreference = "Continue"

$ffmpeg  = "ffmpeg"
$ffprobe = "ffprobe"

# Kodeki wideo, ktorych nie ma sensu przekodowywac.
$skipCodecs = @("av1", "hevc", "h265", "h.265")

# Kodeki audio, ktore mozna skopiowac do MP4 bez ponownego kodowania.
$mp4CopyableAudio = @("aac", "mp3", "mp2", "ac3", "eac3", "opus", "flac", "alac")

# Nazwa pliku przejsciowego tworzonego obok oryginalu podczas podmiany.
$stagedNamePattern = '\.vid2av1-[0-9a-f]{8}\.tmp\.mp4$'

# ---------------------------------------------------------------------------
# Funkcje pomocnicze
# ---------------------------------------------------------------------------

function Test-RequiredTool {
    param(
        [string]$CommandName
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    return ($null -ne $command)
}

function Resolve-FullPath {
    param(
        [string]$InputPath
    )

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
}

function ConvertTo-InvariantDouble {
    param(
        $Value
    )

    [double]$result = 0
    if (($null -ne $Value) -and [double]::TryParse("$Value",
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$result)) {
        return $result
    }

    return -1.0
}

function Format-Duration {
    param(
        [double]$Seconds
    )

    if (($Seconds -lt 0) -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) {
        return "?"
    }

    $ts = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    return ("{0}:{1:mm}:{1:ss}" -f [int][math]::Floor($ts.TotalHours), $ts)
}

function Format-Size {
    param(
        [double]$Bytes
    )

    $sign = ""
    if ($Bytes -lt 0) {
        $sign = "-"
    }
    $abs = [math]::Abs($Bytes)

    if ($abs -ge 1GB) {
        return ("{0}{1:N2} GB" -f $sign, ($abs / 1GB))
    }
    return ("{0}{1:N1} MB" -f $sign, ($abs / 1MB))
}

function Get-FirstProbeValue {
    param(
        [string]$InputFile,
        [string[]]$Arguments
    )

    $value = & $ffprobe @Arguments -- "$InputFile" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    return (($value | Select-Object -First 1) | Out-String).Trim()
}

function Get-VideoInfo {
    param(
        [string]$InputFile
    )

    # Jedno wywolanie ffprobe zamiast kilku osobnych.
    $json = & $ffprobe -v error `
        -show_entries "stream=codec_type,codec_name,width,height,channels,bit_rate:format=duration,bit_rate" `
        -of json -- "$InputFile" 2>$null
    if (($LASTEXITCODE -ne 0) -or (-not $json)) {
        return $null
    }

    try {
        $data = ($json | Out-String) | ConvertFrom-Json
    }
    catch {
        return $null
    }

    $video = @($data.streams | Where-Object { $_.codec_type -eq "video" }) | Select-Object -First 1
    if ($null -eq $video) {
        return $null
    }

    # Bitrate strumienia wideo, a jesli go brak - bitrate calego pliku.
    $bitrate = ConvertTo-InvariantDouble $video.bit_rate
    if ($bitrate -le 0) {
        $bitrate = ConvertTo-InvariantDouble $data.format.bit_rate
    }
    $mbps = 0.0
    if ($bitrate -gt 0) {
        $mbps = $bitrate / 1e6
    }

    $audio = @($data.streams | Where-Object { $_.codec_type -eq "audio" } | ForEach-Object {
        [pscustomobject]@{
            Codec    = "$($_.codec_name)".Trim().ToLower()
            Channels = [int]$_.channels
        }
    })

    return [pscustomobject]@{
        VideoCodec   = "$($video.codec_name)".Trim().ToLower()
        Width        = [int]$video.width
        Height       = [int]$video.height
        Mbps         = $mbps
        Duration     = ConvertTo-InvariantDouble $data.format.duration
        AudioStreams = $audio
    }
}

function Get-DurationSeconds {
    param(
        [string]$InputFile
    )

    $durationStr = Get-FirstProbeValue -InputFile $InputFile -Arguments @(
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=nw=1:nk=1"
    )

    $duration = ConvertTo-InvariantDouble $durationStr
    if ($duration -le 0) {
        return -1.0
    }
    return $duration
}

function Get-AudioCodecArgs {
    param(
        [object[]]$AudioStreams
    )

    $codecArgs = @()
    $index = 0
    foreach ($stream in @($AudioStreams)) {
        if ($null -eq $stream) {
            continue
        }

        if ($mp4CopyableAudio -contains $stream.Codec) {
            $codecArgs += "-c:a:$index", "copy"
            Write-Host ("Audio #{0}: {1}, {2} kan. -> kopia" -f $index, $stream.Codec, $stream.Channels)
        }
        else {
            $audioKbps = 192
            if ($stream.Channels -gt 2) {
                $audioKbps = 384
            }
            $codecArgs += "-c:a:$index", "aac", "-b:a:$index", ("{0}k" -f $audioKbps)
            Write-Host ("Audio #{0}: {1}, {2} kan. -> AAC {3}k (kodek nieobslugiwany w MP4)" -f $index, $stream.Codec, $stream.Channels, $audioKbps)
        }

        $index++
    }

    return ,$codecArgs
}

function Get-TargetBitrateKbps {
    param(
        [int]$Width,
        [int]$Height,
        [double]$SrcMbps
    )

    $resClass = "sd"
    if ($Height -ge 2160 -or $Width -ge 3840) {
        $resClass = "4k"
    }
    elseif ($Height -ge 1440 -or $Width -ge 2560) {
        $resClass = "1440p"
    }
    elseif ($Height -ge 1080 -or $Width -ge 1920) {
        $resClass = "1080p"
    }
    elseif ($Height -ge 720 -or $Width -ge 1280) {
        $resClass = "720p"
    }

    if ($SrcMbps -lt 0.01) {
        switch ($resClass) {
            "4k"    { return 12000 }
            "1440p" { return 8000  }
            "1080p" { return 5000  }
            "720p"  { return 3500  }
            default { return 2000  }
        }
    }

    $factor = 0.4

    switch ($resClass) {
        "4k" {
            if     ($SrcMbps -ge 40) { $factor = 0.30 }
            elseif ($SrcMbps -ge 25) { $factor = 0.35 }
            elseif ($SrcMbps -ge 15) { $factor = 0.45 }
            else                     { $factor = 0.60 }
        }
        "1440p" {
            if     ($SrcMbps -ge 25) { $factor = 0.35 }
            elseif ($SrcMbps -ge 15) { $factor = 0.45 }
            elseif ($SrcMbps -ge 8)  { $factor = 0.55 }
            else                     { $factor = 0.70 }
        }
        "1080p" {
            if     ($SrcMbps -ge 20) { $factor = 0.35 }
            elseif ($SrcMbps -ge 10) { $factor = 0.45 }
            elseif ($SrcMbps -ge 5)  { $factor = 0.60 }
            else                     { $factor = 0.75 }
        }
        "720p" {
            if     ($SrcMbps -ge 10) { $factor = 0.45 }
            elseif ($SrcMbps -ge 6)  { $factor = 0.60 }
            elseif ($SrcMbps -ge 3)  { $factor = 0.75 }
            else                     { $factor = 0.90 }
        }
        "sd" {
            if     ($SrcMbps -ge 5)  { $factor = 0.50 }
            elseif ($SrcMbps -ge 3)  { $factor = 0.65 }
            else                     { $factor = 0.85 }
        }
    }

    $minFactor = 0.25
    if ($factor -lt $minFactor) {
        $factor = $minFactor
    }

    $targetKbps = [int]([double]$SrcMbps * 1000.0 * $factor)
    if ($targetKbps -lt 300) {
        $targetKbps = 300
    }

    return $targetKbps
}

function Test-NvencAvailable {
    # Koduje 1 s obrazu testowego przez CUDA + av1_nvenc, bez zapisu na dysk.
    $output = & $ffmpeg -hide_banner -nostdin -v error `
        -init_hw_device cuda `
        -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 1 `
        -c:v av1_nvenc -preset p4 -f null - 2>&1

    return [pscustomobject]@{
        Ok      = ($LASTEXITCODE -eq 0)
        Message = (($output | Out-String).Trim())
    }
}

$script:recycleLimitCache = @{}

function Get-RecycleBinLimitBytes {
    # Zwraca maksymalny rozmiar pliku, ktory Kosz przyjmie na dysku z FilePath.
    # 0 = brak Kosza (dysk sieciowy/wymienny, Kosz wylaczony). Plik wiekszy niz
    # limit Windows usunalby na stale, wiec takie pliki sa pomijane.
    param(
        [string]$FilePath
    )

    $root = [System.IO.Path]::GetPathRoot($FilePath)
    if ($script:recycleLimitCache.ContainsKey($root)) {
        return $script:recycleLimitCache[$root]
    }

    [long]$limit = 0
    try {
        $drive = New-Object System.IO.DriveInfo($root)
        if ($drive.DriveType -eq [System.IO.DriveType]::Fixed) {
            # Domyslny rozmiar Kosza w Windows to ok. 5% dysku.
            $limit = [long]($drive.TotalSize * 0.05)

            $guid = $null
            try {
                $volume = Get-Volume -DriveLetter $root.Substring(0, 1) -ErrorAction Stop
                if ($volume.UniqueId -match '\{[0-9A-Fa-f-]+\}') {
                    $guid = $Matches[0]
                }
            }
            catch {
            }

            if ($guid) {
                $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\$guid"
                $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
                if ($null -ne $props) {
                    if ($props.NukeOnDelete -eq 1) {
                        $limit = 0
                    }
                    elseif ($props.MaxCapacity) {
                        $limit = [long]$props.MaxCapacity * 1MB
                    }
                }
            }
        }
    }
    catch {
        $limit = 0
    }

    $script:recycleLimitCache[$root] = $limit
    return $limit
}

function Write-RunProgress {
    param(
        [double]$CurrentSeconds = 0,
        [string]$Speed = "",
        [string]$Phase = "Kodowanie"
    )

    $r = $script:run
    $done = $r.DoneMedia + [math]::Max(0, $CurrentSeconds)
    $elapsed = $r.Stopwatch.Elapsed.TotalSeconds

    # ETA calego przebiegu na podstawie przetworzonej dlugosci materialu.
    $eta = -1.0
    if (($r.TotalMedia -gt 0) -and ($done -gt 1) -and ($elapsed -gt 10)) {
        $eta = $elapsed / $done * [math]::Max(0, $r.TotalMedia - $done)
    }

    if ($r.TotalMedia -gt 0) {
        $pct = [int][math]::Min(100, [math]::Max(0, 100 * $done / $r.TotalMedia))
    }
    else {
        $pct = [int](100 * ($r.Index - 1) / [math]::Max(1, $r.Count))
    }

    $status = "Plik {0}/{1} | zaoszczedzono {2} | uplynelo {3} | pozostalo ~{4}" -f `
        $r.Index, $r.Count, (Format-Size $r.Saved), (Format-Duration $elapsed), (Format-Duration $eta)
    Write-Progress -Id 1 -Activity "vid2av1" -Status $status -PercentComplete $pct

    if ($Phase -eq "Kodowanie") {
        $filePct = 0
        $fileEta = -1
        if ($r.CurrentDuration -gt 0) {
            $filePct = [int][math]::Min(100, [math]::Max(0, 100 * $CurrentSeconds / $r.CurrentDuration))
        }

        $speedValue = ConvertTo-InvariantDouble ($Speed.TrimEnd("x"))
        $speedText = "predkosc ?"
        if ($speedValue -gt 0) {
            $speedText = "predkosc {0:N1}x" -f $speedValue
            if ($r.CurrentDuration -gt 0) {
                $fileEta = [int][math]::Max(0, ($r.CurrentDuration - $CurrentSeconds) / $speedValue)
            }
        }

        $fileStatus = "{0}% | {1} / {2} | {3}" -f `
            $filePct, (Format-Duration $CurrentSeconds), (Format-Duration $r.CurrentDuration), $speedText
        Write-Progress -Id 2 -ParentId 1 -Activity ("Kodowanie: {0}" -f $r.CurrentName) `
            -Status $fileStatus -PercentComplete $filePct -SecondsRemaining $fileEta
    }
    else {
        Write-Progress -Id 2 -ParentId 1 -Activity ("{0}: {1}" -f $Phase, $r.CurrentName) -Status "prosze czekac..."
    }
}

function Invoke-Av1Encode {
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [int]$TargetKbps,
        [string[]]$AudioArgs = @(),
        [string]$EncodePreset = "p4"
    )

    if (Test-Path -LiteralPath $OutputFile) {
        Remove-Item -LiteralPath $OutputFile -Force -ErrorAction SilentlyContinue -Confirm:$false
    }

    $b  = "{0}k" -f $TargetKbps
    $mx = "{0}k" -f [int]([double]$TargetKbps * 1.3)
    $bf = "{0}k" -f [int]([double]$TargetKbps * 3.0)

    Write-Host ("Kodowanie: b={0} max={1} buf={2} preset={3}" -f $b, $mx, $bf, $EncodePreset)

    # -progress pipe:1 wysyla postep na stdout (czytany ponizej), a ffmpeg
    # wypisuje na konsole tylko ostrzezenia i bledy.
    $ffArgs = @(
        "-hide_banner", "-nostdin", "-loglevel", "warning", "-nostats",
        "-progress", "pipe:1",
        "-y",
        "-hwaccel", "cuda",
        "-hwaccel_output_format", "cuda",
        "-i", $InputFile,
        "-map", "0:v:0", "-map", "0:a?",
        "-c:v", "av1_nvenc",
        "-preset", $EncodePreset,
        "-rc", "vbr",
        "-b:v", $b,
        "-maxrate", $mx,
        "-bufsize", $bf,
        "-spatial-aq", "1",
        "-temporal-aq", "1",
        "-aq-strength", "10",
        "-rc-lookahead", "48",
        "-bf", "7"
    ) + $AudioArgs + @(
        "-movflags", "+faststart",
        $OutputFile
    )

    $speed = ""
    Write-RunProgress -CurrentSeconds 0
    & $ffmpeg @ffArgs | ForEach-Object {
        $line = "$_"
        if ($line.StartsWith("out_time_us=")) {
            [long]$us = 0
            if ([long]::TryParse($line.Substring(12), [ref]$us) -and ($us -ge 0)) {
                Write-RunProgress -CurrentSeconds ($us / 1e6) -Speed $speed
            }
        }
        elseif ($line.StartsWith("speed=")) {
            $speed = $line.Substring(6).Trim()
        }
    }
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-Warning ("Kodowanie nie powiodlo sie. ffmpeg exit code: {0}" -f $exitCode)
        return $false
    }

    $outputItem = Get-Item -LiteralPath $OutputFile -ErrorAction SilentlyContinue
    if (($null -eq $outputItem) -or ($outputItem.Length -le 0)) {
        Write-Warning "Kodowanie nie utworzylo pliku wyjsciowego albo jest on pusty."
        return $false
    }

    return $true
}

function Test-Av1OutputFile {
    param(
        [string]$OutputFile
    )

    $outputItem = Get-Item -LiteralPath $OutputFile -ErrorAction SilentlyContinue
    if (($null -eq $outputItem) -or ($outputItem.Length -le 0)) {
        Write-Warning "Walidacja: plik wyjsciowy nie istnieje albo jest pusty."
        return $false
    }

    $codec = Get-FirstProbeValue -InputFile $OutputFile -Arguments @(
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=codec_name",
        "-of", "default=nw=1:nk=1"
    )
    $codec = $codec.Trim().ToLower()

    if ($codec -ne "av1") {
        Write-Warning ("Walidacja: oczekiwano AV1, wykryto '{0}'." -f $codec)
        return $false
    }

    & $ffmpeg -hide_banner -nostdin -v error -xerror -i "$OutputFile" -map 0 -f null - 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("Walidacja: ffmpeg nie odczytal calego pliku. Exit code: {0}" -f $LASTEXITCODE)
        return $false
    }

    return $true
}

function Remove-OriginalFile {
    # Usuwa oryginal zgodnie z trybem. Zwraca opis, gdzie trafil.
    param(
        [string]$File,
        [string]$Mode,
        [string]$SourceRootPrefix,
        [string]$ArchiveRoot
    )

    switch ($Mode) {
        "Recycle" {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($File,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException)
            return "Kosz"
        }
        "Archive" {
            $relative = $File.Substring($SourceRootPrefix.Length)
            $dest = Join-Path $ArchiveRoot $relative
            $destDir = Split-Path -Parent $dest
            [System.IO.Directory]::CreateDirectory($destDir) | Out-Null

            if (Test-Path -LiteralPath $dest) {
                $dest = Join-Path $destDir ("{0}_{1}{2}" -f `
                    [System.IO.Path]::GetFileNameWithoutExtension($dest),
                    [guid]::NewGuid().ToString("N").Substring(0, 8),
                    [System.IO.Path]::GetExtension($dest))
            }

            Move-Item -LiteralPath $File -Destination $dest -ErrorAction Stop -Confirm:$false
            return $dest
        }
        default {
            Remove-Item -LiteralPath $File -Force -ErrorAction Stop -Confirm:$false
            return "Usunieto na stale"
        }
    }
}

function Install-EncodedFile {
    param(
        [string]$InputFile,
        [string]$EncodedFile,
        [string]$FinalFile,
        [string]$Mode,
        [string]$SourceRootPrefix,
        [string]$ArchiveRoot
    )

    $inputFull = [System.IO.Path]::GetFullPath($InputFile)
    $finalFull = [System.IO.Path]::GetFullPath($FinalFile)
    $sameFinalAsInput = [string]::Equals($inputFull, $finalFull, [System.StringComparison]::OrdinalIgnoreCase)

    if ((-not $sameFinalAsInput) -and (Test-Path -LiteralPath $FinalFile)) {
        return [pscustomobject]@{ Ok = $false; Message = ("docelowy plik juz istnieje: {0}" -f $FinalFile); Original = "" }
    }

    # 1) Wynik trafia obok oryginalu (dla .mp4 -> .mp4 pod nazwa przejsciowa).
    $stagedFile = $FinalFile
    if ($sameFinalAsInput) {
        $stagedFile = Join-Path (Split-Path -Parent $FinalFile) ("{0}.vid2av1-{1}.tmp.mp4" -f `
            [System.IO.Path]::GetFileNameWithoutExtension($FinalFile),
            [guid]::NewGuid().ToString("N").Substring(0, 8))
    }

    try {
        Move-Item -LiteralPath $EncodedFile -Destination $stagedFile -ErrorAction Stop -Confirm:$false
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Message = ("nie mozna przeniesc wyniku: {0}" -f $_.Exception.Message); Original = "" }
    }

    # 2) Oryginal do Kosza / archiwum / usuniety. Przy bledzie oryginal zostaje,
    #    a wynik jest wycofywany.
    try {
        $originalWhere = Remove-OriginalFile -File $InputFile -Mode $Mode -SourceRootPrefix $SourceRootPrefix -ArchiveRoot $ArchiveRoot
    }
    catch {
        Remove-Item -LiteralPath $stagedFile -Force -ErrorAction SilentlyContinue -Confirm:$false
        return [pscustomobject]@{ Ok = $false; Message = ("nie mozna usunac oryginalu: {0}" -f $_.Exception.Message); Original = "" }
    }

    # 3) Dla .mp4 -> .mp4: wynik dostaje nazwe oryginalu.
    if ($sameFinalAsInput) {
        try {
            Move-Item -LiteralPath $stagedFile -Destination $FinalFile -ErrorAction Stop -Confirm:$false
        }
        catch {
            $msg = "oryginal: {0}; wynik zostal pod nazwa {1} ({2})" -f $originalWhere, $stagedFile, $_.Exception.Message
            return [pscustomobject]@{ Ok = $false; Message = $msg; Original = $originalWhere }
        }
    }

    return [pscustomobject]@{ Ok = $true; Message = ""; Original = $originalWhere }
}

function New-ResultRecord {
    param(
        [System.IO.FileInfo]$Item,
        [string]$RelativePath,
        $Info
    )

    $codec = ""
    $resolution = ""
    $mbps = $null
    $duration = $null
    if ($null -ne $Info) {
        $codec = $Info.VideoCodec
        $resolution = "{0}x{1}" -f $Info.Width, $Info.Height
        $mbps = [math]::Round($Info.Mbps, 2)
        if ($Info.Duration -gt 0) {
            $duration = [math]::Round($Info.Duration, 2)
        }
    }

    return [pscustomobject]@{
        Plik            = $RelativePath
        Status          = ""
        Powod           = ""
        Kodek           = $codec
        Rozdzielczosc   = $resolution
        ZrodloMbps      = $mbps
        DocelowyKbps    = $null
        DlugoscZrodlaS  = $duration
        DlugoscWynikuS  = $null
        ZrodloMB        = [math]::Round($Item.Length / 1MB, 2)
        WynikMB         = $null
        ZaoszczedzonoMB = $null
        Ratio           = $null
        CzasS           = $null
        Oryginal        = ""
    }
}

function Write-LogRecord {
    param(
        $Record
    )

    if (-not $script:logFile) {
        return
    }

    # Liczby w formacie lokalnym i separator z ustawien regionalnych, zeby
    # plik otwieral sie poprawnie w Excelu.
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    $row = [ordered]@{}
    foreach ($prop in $Record.PSObject.Properties) {
        $value = $prop.Value
        if ($value -is [double]) {
            $value = $value.ToString($culture)
        }
        $row[$prop.Name] = $value
    }

    $csvParams = @{
        LiteralPath = $script:logFile
        Append      = $true
        UseCulture  = $true
        Encoding    = $script:csvEncoding
        Confirm     = $false
        WhatIf      = $false
        ErrorAction = "Stop"
    }
    # Windows PowerShell 5.1 dopisuje naglowek typu bez tej opcji; w 7+ jest przestarzala.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $csvParams.NoTypeInformation = $true
    }

    try {
        [pscustomobject]$row | Export-Csv @csvParams
    }
    catch {
        Write-Warning ("Nie mozna zapisac logu CSV ({0}). Log wylaczony." -f $_.Exception.Message)
        $script:logFile = $null
    }
}

function Write-Summary {
    param(
        [System.Collections.Generic.List[object]]$Results,
        [System.Diagnostics.Stopwatch]$Stopwatch
    )

    Write-Host ""
    Write-Host "============== PODSUMOWANIE =============="

    foreach ($status in @("Skonwertowano", "Odrzucono", "Blad", "Przerwano", "Pominieto")) {
        $count = @($Results | Where-Object { $_.Status -eq $status }).Count
        if ($count -gt 0) {
            Write-Host ("{0,-14} {1}" -f ($status + ":"), $count)
        }
    }

    $converted = @($Results | Where-Object { $_.Status -eq "Skonwertowano" })
    if ($converted.Count -gt 0) {
        $srcMB = ($converted | Measure-Object -Property ZrodloMB -Sum).Sum
        $outMB = ($converted | Measure-Object -Property WynikMB -Sum).Sum
        Write-Host ("Zaoszczedzono: {0} ({1} -> {2})" -f `
            (Format-Size (($srcMB - $outMB) * 1MB)), (Format-Size ($srcMB * 1MB)), (Format-Size ($outMB * 1MB)))
    }
    if ($null -ne $Stopwatch) {
        Write-Host ("Czas:          {0}" -f (Format-Duration $Stopwatch.Elapsed.TotalSeconds))
    }

    $problems = @($Results | Where-Object { @("Odrzucono", "Blad", "Przerwano") -contains $_.Status })
    if ($problems.Count -gt 0) {
        Write-Host ""
        Write-Host "Pliki, ktorych oryginal zostal (albo wymagaja uwagi):"
        $problems | Format-Table -Property Plik, Status, Powod -AutoSize -Wrap | Out-Host
    }

    $skipped = @($Results | Where-Object { $_.Status -eq "Pominieto" })
    if ($skipped.Count -gt 0) {
        Write-Host ""
        Write-Host "Pominiete (powod: liczba):"
        $skipped | Group-Object -Property Powod | Sort-Object -Property Count -Descending | ForEach-Object {
            Write-Host ("  {0}: {1}" -f $_.Name, $_.Count)
        }
    }

    if ($script:logFile) {
        Write-Host ""
        Write-Host ("Log CSV: {0}" -f $script:logFile)
    }
}

# ---------------------------------------------------------------------------
# Ustawienia
# ---------------------------------------------------------------------------

$isDryRun = [bool]$WhatIfPreference

if ($ArchivePath -and $PermanentDelete) {
    Write-Error "Uzyj albo -ArchivePath, albo -PermanentDelete, nie obu naraz."
    exit 1
}

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Error ("Folder nie istnieje: {0}" -f $Path)
    exit 1
}

$root = (Resolve-Path -LiteralPath $Path).ProviderPath
$rootPrefix = $root.TrimEnd("\") + "\"

$tempFull = Join-Path $root "av1_nvenc"
if ($TempDir) {
    $tempFull = Resolve-FullPath $TempDir
}

$disposalMode = "Recycle"
$archiveFull = $null
if ($ArchivePath) {
    $disposalMode = "Archive"
    $archiveFull = Resolve-FullPath $ArchivePath
}
elseif ($PermanentDelete) {
    $disposalMode = "Delete"
}

$script:logFile = $null
if ((-not $NoLog) -and (-not $isDryRun)) {
    if ($LogPath) {
        $script:logFile = Resolve-FullPath $LogPath
    }
    else {
        $script:logFile = Join-Path $root ("vid2av1-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
    }
}
$script:csvEncoding = "UTF8"
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $script:csvEncoding = "utf8BOM"
}

$allowedExt = @($Extensions | ForEach-Object { "." + $_.Trim().TrimStart("*").TrimStart(".").ToLower() } |
    Where-Object { $_ -ne "." } | Select-Object -Unique)

$disposalText = switch ($disposalMode) {
    "Recycle" { "do Kosza" }
    "Archive" { "przeniesione do {0}" -f $archiveFull }
    default   { "usuwane NA STALE" }
}

Write-Host "================ vid2av1 ================"
Write-Host ("Folder:        {0}{1}" -f $root, $(if ($NoRecurse) { " (bez podfolderow)" } else { " (z podfolderami)" }))
Write-Host ("Rozszerzenia:  {0}" -f ($allowedExt -join " "))
Write-Host ("Preset:        {0}, tolerancja dlugosci {1} s" -f $Preset, $DurationTolerance)
Write-Host ("Oryginaly:     {0}" -f $disposalText)
if ($isDryRun) {
    Write-Host "Tryb:          -WhatIf (nic nie zostanie zakodowane ani usuniete)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Kontrola narzedzi i GPU
# ---------------------------------------------------------------------------

if (-not (Test-RequiredTool -CommandName $ffmpeg)) {
    Write-Error "Brak ffmpeg w PATH."
    exit 1
}
if (-not (Test-RequiredTool -CommandName $ffprobe)) {
    Write-Error "Brak ffprobe w PATH."
    exit 1
}

if (-not $SkipGpuCheck) {
    Write-Host "Test GPU (CUDA + av1_nvenc)..."
    $gpu = Test-NvencAvailable
    if ($gpu.Ok) {
        Write-Host "GPU: OK"
    }
    else {
        $gpuMessage = "Test av1_nvenc nie powiodl sie. Sprawdz sterownik NVIDIA, GPU i czy ffmpeg ma wsparcie NVENC/CUDA."
        if ($gpu.Message) {
            $gpuMessage += [Environment]::NewLine + "ffmpeg: " + $gpu.Message
        }
        if ($isDryRun) {
            Write-Warning $gpuMessage
        }
        else {
            Write-Error $gpuMessage
            exit 1
        }
    }
}

if ($disposalMode -eq "Recycle") {
    Add-Type -AssemblyName Microsoft.VisualBasic
}

# ---------------------------------------------------------------------------
# Wyszukiwanie plikow
# ---------------------------------------------------------------------------

# Lista jest budowana z gory, zeby nowo utworzone pliki .mp4 nie trafily do
# przetwarzania. Pomija folder tymczasowy, folder archiwum i pliki przejsciowe.
$excludePrefixes = @($tempFull.TrimEnd("\") + "\")
if ($archiveFull) {
    $excludePrefixes += $archiveFull.TrimEnd("\") + "\"
}

$gciParams = @{
    LiteralPath = $root
    File        = $true
    ErrorAction = "SilentlyContinue"
}
if (-not $NoRecurse) {
    $gciParams.Recurse = $true
}

Write-Host "Szukam plikow..."
$videoFiles = @(Get-ChildItem @gciParams | Where-Object {
    $fullName = $_.FullName
    ($allowedExt -contains $_.Extension.ToLower()) -and
    ($_.Name -notmatch $stagedNamePattern) -and
    (-not ($excludePrefixes | Where-Object { $fullName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }))
} | Sort-Object -Property FullName)

Write-Host ("Znaleziono plikow wideo: {0}" -f $videoFiles.Count)

# ---------------------------------------------------------------------------
# Analiza i plan
# ---------------------------------------------------------------------------

$results = New-Object System.Collections.Generic.List[object]
$plan = New-Object System.Collections.Generic.List[object]

$analyzeIndex = 0
foreach ($item in $videoFiles) {
    $analyzeIndex++
    Write-Progress -Id 1 -Activity "vid2av1: analiza plikow" `
        -Status ("{0}/{1}: {2}" -f $analyzeIndex, $videoFiles.Count, $item.Name) `
        -PercentComplete ([int](100 * ($analyzeIndex - 1) / [math]::Max(1, $videoFiles.Count)))

    $relative = $item.FullName.Substring($rootPrefix.Length)
    $info = Get-VideoInfo -InputFile $item.FullName
    $record = New-ResultRecord -Item $item -RelativePath $relative -Info $info
    $finalPath = Join-Path $item.DirectoryName ($item.BaseName + ".mp4")
    $sameFinal = [string]::Equals($item.FullName, $finalPath, [System.StringComparison]::OrdinalIgnoreCase)

    $skipReason = $null
    if ($null -eq $info) {
        $skipReason = "nie mozna odczytac strumienia wideo"
    }
    elseif ($skipCodecs -contains $info.VideoCodec) {
        $skipReason = "juz w kodeku {0}" -f $info.VideoCodec
    }
    elseif ((-not $sameFinal) -and (Test-Path -LiteralPath $finalPath)) {
        $skipReason = "docelowy plik .mp4 juz istnieje"
    }
    elseif ($disposalMode -eq "Recycle") {
        $limit = Get-RecycleBinLimitBytes -FilePath $item.FullName
        if ($limit -le 0) {
            $skipReason = "brak Kosza na tym dysku - uzyj -ArchivePath lub -PermanentDelete"
        }
        elseif ($item.Length -gt $limit) {
            $skipReason = "plik wiekszy niz limit Kosza ({0}) - uzyj -ArchivePath lub -PermanentDelete" -f (Format-Size $limit)
        }
    }

    if ($skipReason) {
        $record.Status = "Pominieto"
        $record.Powod = $skipReason
        $results.Add($record)
        continue
    }

    $record.DocelowyKbps = Get-TargetBitrateKbps -Width $info.Width -Height $info.Height -SrcMbps $info.Mbps
    $record.Status = "Zaplanowano"
    $plan.Add([pscustomobject]@{
        Item      = $item
        Info      = $info
        Record    = $record
        FinalPath = $finalPath
    })
}
Write-Progress -Id 1 -Activity "vid2av1: analiza plikow" -Completed

$planBytes = ($plan | ForEach-Object { $_.Item.Length } | Measure-Object -Sum).Sum
$planSeconds = ($plan | ForEach-Object { [math]::Max(0, $_.Info.Duration) } | Measure-Object -Sum).Sum
if ($null -eq $planBytes) { $planBytes = 0 }
if ($null -eq $planSeconds) { $planSeconds = 0 }

Write-Host ("Do zakodowania: {0} ({1}, laczna dlugosc {2})" -f $plan.Count, (Format-Size $planBytes), (Format-Duration $planSeconds))
Write-Host ("Pominietych:    {0}" -f $results.Count)

# ---------------------------------------------------------------------------
# Tryb -WhatIf: tylko plan
# ---------------------------------------------------------------------------

if ($isDryRun) {
    if ($plan.Count -gt 0) {
        Write-Host ""
        Write-Host "Zostalyby zakodowane:"
        $plan | ForEach-Object { $_.Record } |
            Format-Table -Property Plik, Kodek, Rozdzielczosc, ZrodloMbps, DocelowyKbps, ZrodloMB, DlugoscZrodlaS -AutoSize |
            Out-Host
    }
    if ($results.Count -gt 0) {
        Write-Host ""
        Write-Host "Zostalyby pominiete:"
        $results | Format-Table -Property Plik, Kodek, Powod -AutoSize -Wrap | Out-Host
    }
    Write-Host "Tryb -WhatIf: nic nie zostalo zakodowane ani usuniete."
    exit 0
}

# ---------------------------------------------------------------------------
# Kodowanie
# ---------------------------------------------------------------------------

foreach ($record in $results) {
    Write-LogRecord -Record $record
}

$tempExisted = Test-Path -LiteralPath $tempFull
if ($plan.Count -gt 0) {
    [System.IO.Directory]::CreateDirectory($tempFull) | Out-Null
}

$script:run = @{
    Stopwatch       = [System.Diagnostics.Stopwatch]::StartNew()
    TotalMedia      = [double]$planSeconds
    DoneMedia       = 0.0
    Index           = 0
    Count           = $plan.Count
    Saved           = 0.0
    CurrentDuration = 0.0
    CurrentName     = ""
}

try {
    foreach ($entry in $plan) {
        $script:run.Index++
        $record = $entry.Record
        $file = $entry.Item.FullName

        if (-not $PSCmdlet.ShouldProcess($record.Plik, "Kodowanie AV1 i zastapienie oryginalu")) {
            $record.Status = "Pominieto"
            $record.Powod = "odrzucone przez uzytkownika"
            $results.Add($record)
            Write-LogRecord -Record $record
            continue
        }

        $script:run.CurrentDuration = [math]::Max(0, $entry.Info.Duration)
        $script:run.CurrentName = $entry.Item.Name

        Write-Host ""
        Write-Host "===================================="
        Write-Host ("[{0}/{1}] {2}" -f $script:run.Index, $script:run.Count, $record.Plik)
        Write-Host ("{0}, {1}, {2:N2} Mb/s, {3}, {4}" -f `
            $record.Kodek, $record.Rozdzielczosc, $entry.Info.Mbps, (Format-Size $entry.Item.Length), (Format-Duration $entry.Info.Duration))
        Write-Host ("Docelowy bitrate: {0} kb/s (min 25% zrodla, gdy bitrate jest znany)" -f $record.DocelowyKbps)
        Write-Host "===================================="

        $fileStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $tmpOutPath = Join-Path $tempFull ($entry.Item.BaseName + "_av1.tmp.mp4")
        $record.Status = "Przerwano"
        $record.Powod = "przerwano przed zakonczeniem (Ctrl+C)"

        try {
            $audioArgs = Get-AudioCodecArgs -AudioStreams $entry.Info.AudioStreams

            $encoded = Invoke-Av1Encode -InputFile $file -OutputFile $tmpOutPath -TargetKbps $record.DocelowyKbps `
                -AudioArgs $audioArgs -EncodePreset $Preset

            if (-not $encoded) {
                $record.Status = "Blad"
                $record.Powod = "kodowanie nie powiodlo sie"
            }
            else {
                Write-RunProgress -CurrentSeconds $script:run.CurrentDuration -Phase "Walidacja"
                $valid = Test-Av1OutputFile -OutputFile $tmpOutPath

                $outDuration = Get-DurationSeconds -InputFile $tmpOutPath
                $sameDuration = $false
                if (($entry.Info.Duration -gt 0) -and ($outDuration -gt 0)) {
                    $diff = [math]::Abs($entry.Info.Duration - $outDuration)
                    $sameDuration = ($diff -le $DurationTolerance)
                    Write-Host ("Dlugosc: zrodlo = {0:N2} s, wynik = {1:N2} s (roznica {2:N2} s, tolerancja {3:N2} s)" -f `
                        $entry.Info.Duration, $outDuration, $diff, $DurationTolerance)
                }
                else {
                    Write-Warning "Dlugosc: nie mozna odczytac dlugosci zrodla albo wyniku."
                }
                if ($outDuration -gt 0) {
                    $record.DlugoscWynikuS = [math]::Round($outDuration, 2)
                }

                $outSize = (Get-Item -LiteralPath $tmpOutPath).Length
                $ratio = [double]$outSize / [double]$entry.Item.Length
                $smaller = ($ratio -lt 1.0)
                $record.WynikMB = [math]::Round($outSize / 1MB, 2)
                $record.Ratio = [math]::Round($ratio, 4)
                Write-Host ("Rozmiar: zrodlo = {0}, wynik = {1} ({2:P1})" -f `
                    (Format-Size $entry.Item.Length), (Format-Size $outSize), $ratio)

                $reasons = @()
                if (-not $valid)        { $reasons += "wynik nie przeszedl walidacji" }
                if (-not $sameDuration) { $reasons += "inna dlugosc niz zrodlo" }
                if (-not $smaller)      { $reasons += "wynik nie jest mniejszy" }

                if ($reasons.Count -gt 0) {
                    $record.Status = "Odrzucono"
                    $record.Powod = $reasons -join "; "
                    Write-Warning ("Nie zastepuje oryginalu: {0}." -f $record.Powod)
                }
                else {
                    Write-RunProgress -CurrentSeconds $script:run.CurrentDuration -Phase "Podmiana"
                    $install = Install-EncodedFile -InputFile $file -EncodedFile $tmpOutPath -FinalFile $entry.FinalPath `
                        -Mode $disposalMode -SourceRootPrefix $rootPrefix -ArchiveRoot $archiveFull

                    $record.Oryginal = $install.Original
                    if ($install.Ok) {
                        $saved = $entry.Item.Length - $outSize
                        $script:run.Saved += $saved
                        $record.Status = "Skonwertowano"
                        $record.Powod = ""
                        $record.ZaoszczedzonoMB = [math]::Round($saved / 1MB, 2)
                        Write-Host ("[OK] {0} (oszczednosc {1}, oryginal: {2})" -f `
                            $entry.FinalPath, (Format-Size $saved), $install.Original)
                    }
                    else {
                        $record.Status = "Blad"
                        $record.Powod = $install.Message
                        Write-Warning ("Podmiana nie powiodla sie: {0}" -f $install.Message)
                    }
                }
            }
        }
        finally {
            # Sprzatanie pliku tymczasowego (oryginal nie jest tu dotykany).
            if (Test-Path -LiteralPath $tmpOutPath) {
                Remove-Item -LiteralPath $tmpOutPath -Force -ErrorAction SilentlyContinue -Confirm:$false
            }

            $record.CzasS = [math]::Round($fileStopwatch.Elapsed.TotalSeconds, 1)
            $script:run.DoneMedia += $script:run.CurrentDuration
            $results.Add($record)
            Write-LogRecord -Record $record
        }
    }
}
finally {
    Write-Progress -Id 2 -ParentId 1 -Activity "vid2av1" -Completed
    Write-Progress -Id 1 -Activity "vid2av1" -Completed

    # Usun folder tymczasowy, jesli zostal utworzony przez ten skrypt i jest pusty.
    if ((-not $tempExisted) -and (Test-Path -LiteralPath $tempFull)) {
        if (-not (Get-ChildItem -LiteralPath $tempFull -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $tempFull -Force -ErrorAction SilentlyContinue -Confirm:$false
        }
    }

    Write-Summary -Results $results -Stopwatch $script:run.Stopwatch
}
