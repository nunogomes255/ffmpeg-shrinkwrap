<#
.SYNOPSIS
    FFmpeg Shrinkwrap - Constraint-Driven MP4 Optimizer for Discord
    Full-featured Windows port with rescue modes, splitting, and adaptive encoding

.DESCRIPTION
    Automatically compresses videos to fit Discord's 10MB limit using intelligent
    fallback strategies: 2-pass encoding -> CRF rescue -> 720p downscale -> split at keyframes

.PARAMETER Files
    Video files to process. If none specified, processes all .mp4 files in current directory

.PARAMETER Preset
    FFmpeg x265 preset (ultrafast/superfast/veryfast/faster/fast/medium/slow/slower/veryslow)
    Default: slow

.PARAMETER TargetSizeMB
    Target file size in MB. Default: 9.8

.PARAMETER MinVideoBitrate
    Minimum video bitrate floor in kbps. Default: 500

.PARAMETER MinAudioBitrate
    Minimum audio bitrate floor in kbps. Default: 64

.PARAMETER MaxRetries
    Maximum encoding retry attempts per pass. Default: 3

.PARAMETER NoCleanup
    Preserve logs and temporary files for debugging

.PARAMETER NormalizeAudio
    Apply EBU R128 loudness normalization (-16 LUFS target, two-pass mode)

.EXAMPLE
    .\shrinkwrap.ps1
    Process all .mp4 files in current directory

.EXAMPLE
    .\shrinkwrap.ps1 -Files "gameplay.mp4","clip.mp4"
    Process specific files

.EXAMPLE
    .\shrinkwrap.ps1 -TargetSizeMB 8 -Preset faster -NormalizeAudio
    Process with custom settings and audio normalization
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Files,
    
    [string]$Preset = "slow",
    [double]$TargetSizeMB = 9.8,
    [int]$MinVideoBitrate = 500,
    [int]$MinAudioBitrate = 64,
    [int]$MaxRetries = 3,
    [switch]$NoCleanup,
    [switch]$NormalizeAudio
)

$ErrorActionPreference = "Continue" # Changed from "Stop" to handle FFmpeg stderr gracefully
$ProgressPreference = "SilentlyContinue" # Disable built-in progress for speed

# --- Configuration Constants ---
$Script:MAX_SIZE_MB = 10.0
$Script:INITIAL_AUDIO_BITRATE_KBPS = 192
$Script:OVERHEAD_KB = 200
$Script:MAX_VIDEO_BITRATE_KBPS = 50000
$Script:OUTPUT_DIR = Join-Path $PSScriptRoot "optimized"
$Script:SUMMARY_FILE = "optimization_summary.txt"

# --- Audio Normalization Cache ---
$Script:AudioNormCache = @{}

# --- Reporting Structures ---
$Script:ProcessedFiles = @()
$Script:OriginalSizes = @()
$Script:FinalSizes = @()
$Script:Reductions = @()
$Script:Statuses = @()

# --- Utility Functions ---

function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Test-Dependency {
    param([string]$Command)
    try {
        $null = Get-Command $Command -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-FFmpegPath {
    # Check local directory first
    $LocalFFmpeg = Join-Path $PSScriptRoot "ffmpeg.exe"
    if (Test-Path $LocalFFmpeg) { return $LocalFFmpeg }
    
    # Check PATH
    if (Test-Dependency "ffmpeg") { return "ffmpeg" }
    
    Write-ColorOutput "ERROR: FFmpeg not found!" "Red"
    Write-ColorOutput "Please download ffmpeg.exe and place it in: $PSScriptRoot" "Yellow"
    Write-ColorOutput "Download from: https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-essentials.7z" "Cyan"
    Read-Host "Press Enter to exit"
    exit 1
}

function Get-FFprobePath {
    $LocalFFprobe = Join-Path $PSScriptRoot "ffprobe.exe"
    if (Test-Path $LocalFFprobe) { return $LocalFFprobe }
    if (Test-Dependency "ffprobe") { return "ffprobe" }
    return $null
}

function Get-Duration {
    param([string]$FilePath)
    
    $Result = & $Script:FFprobe -v error -show_entries format=duration `
        -of default=noprint_wrappers=1:nokey=1 $FilePath 2>$null
    
    if ($Result) {
        return [double]$Result
    }
    return 0
}

function Get-FileSizeMB {
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) { return 0 }
    $Item = Get-Item $FilePath -ErrorAction SilentlyContinue
    if (-not $Item -or $Item.Length -eq 0) { return 0 }
    return [math]::Round($Item.Length / 1MB, 3)
}

function Get-NearestKeyframe {
    param([string]$FilePath, [double]$TargetTime)
    
    # Find keyframe nearest to target time
    $KeyframesRaw = & $Script:FFprobe -v error -skip_frame nokey -select_streams v:0 `
        -show_entries frame=pkt_pts_time -of csv=p=0 $FilePath 2>$null
    
    $Keyframes = @()
    foreach ($Line in $KeyframesRaw) {
        $Parts = $Line -split ','
        if ($Parts.Count -eq 2 -and $Parts[1] -eq '1') {
            $Time = [double]$Parts[0]
            if ($Time -gt 0 -and $Time -lt $TargetTime) {
                $Keyframes += $Time
            }
        }
    }
    
    if ($Keyframes.Count -gt 0) {
        return $Keyframes[-1] # Return last keyframe before target
    }
    return $TargetTime # Fallback to target time
}

function Get-AudioLoudnessFilter {
    param([string]$InputFile)
    
    if (-not $NormalizeAudio) {
        return $null
    }
    
    $CacheKey = [System.IO.Path]::GetFileName($InputFile)
    
    # Check cache
    if ($Script:AudioNormCache.ContainsKey($CacheKey)) {
        return $Script:AudioNormCache[$CacheKey]
    }
    
    Write-ColorOutput "  [Audio Analysis] Measuring loudness (two-pass mode)..." "Gray"
    
    # Create temp file for JSON output
    $JsonFile = Join-Path $Script:OUTPUT_DIR "$([System.IO.Path]::GetFileNameWithoutExtension($InputFile))_loudnorm_$PID.json"
    
    # Run analysis pass
    try {
        $AnalysisArgs = @(
            "-i", $InputFile,
            "-af", "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json",
            "-f", "null",
            "-"
        )
        
        $Process = Start-Process -FilePath $Script:FFmpeg -ArgumentList $AnalysisArgs `
            -NoNewWindow -Wait -PassThru -RedirectStandardError $JsonFile
        
        if (-not (Test-Path $JsonFile) -or (Get-Item $JsonFile).Length -eq 0) {
            Write-ColorOutput "  [Warning] Audio analysis failed, falling back to single-pass" "Yellow"
            Remove-Item $JsonFile -ErrorAction SilentlyContinue
            $FallbackFilter = "loudnorm=I=-16:TP=-1.5:LRA=11"
            $Script:AudioNormCache[$CacheKey] = $FallbackFilter
            return $FallbackFilter
        }
        
        # Extract JSON from stderr (FFmpeg writes this to stderr)
        $Content = Get-Content $JsonFile -Raw
        
        # Find the JSON block (between curly braces after "Parsed_loudnorm")
        if ($Content -match '(?s)\{[^}]*"input_i"[^}]*\}') {
            $JsonBlock = $Matches[0]
            
            try {
                $LoudnessData = $JsonBlock | ConvertFrom-Json
                
                $InputI = $LoudnessData.input_i
                $InputTP = $LoudnessData.input_tp
                $InputLRA = $LoudnessData.input_lra
                $InputThresh = $LoudnessData.input_thresh
                $TargetOffset = $LoudnessData.target_offset
                
                # Validate all values exist
                if ($InputI -and $InputTP -and $InputLRA -and $InputThresh -and $TargetOffset) {
                    Write-ColorOutput "  [Audio Analysis] Measured: $InputI LUFS (target: -16 LUFS)" "Gray"
                    
                    $TwoPassFilter = "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=${InputI}:measured_TP=${InputTP}:measured_LRA=${InputLRA}:measured_thresh=${InputThresh}:offset=${TargetOffset}:linear=true"
                    
                    $Script:AudioNormCache[$CacheKey] = $TwoPassFilter
                    Remove-Item $JsonFile -ErrorAction SilentlyContinue
                    return $TwoPassFilter
                }
            } catch {
                Write-ColorOutput "  [Warning] Failed to parse loudness data: $_" "Yellow"
            }
        }
        
        # Fallback to single-pass if parsing fails
        Write-ColorOutput "  [Warning] Could not parse loudness measurements, using single-pass" "Yellow"
        Remove-Item $JsonFile -ErrorAction SilentlyContinue
        $FallbackFilter = "loudnorm=I=-16:TP=-1.5:LRA=11"
        $Script:AudioNormCache[$CacheKey] = $FallbackFilter
        return $FallbackFilter
        
    } catch {
        Write-ColorOutput "  [Warning] Audio analysis failed: $_, falling back to single-pass" "Yellow"
        Remove-Item $JsonFile -ErrorAction SilentlyContinue
        $FallbackFilter = "loudnorm=I=-16:TP=-1.5:LRA=11"
        $Script:AudioNormCache[$CacheKey] = $FallbackFilter
        return $FallbackFilter
    }
}

function Show-Progress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete
    )
    
    # Simple progress bar since we can't easily parse FFmpeg progress in PowerShell
    $Width = 40
    $Filled = [math]::Floor($Width * $PercentComplete / 100)
    $Empty = $Width - $Filled
    
    $Bar = "#" * $Filled + "-" * $Empty
    Write-Host "`r  $Status [$Bar] $PercentComplete%" -NoNewline
}

function Record-Summary {
    param(
        [string]$FileName,
        [double]$OrigSize,
        [string]$FinalSize,
        [string]$Status
    )
    
    $Script:ProcessedFiles += $FileName
    $Script:OriginalSizes += $OrigSize
    $Script:FinalSizes += $FinalSize
    
    $Reduction = "N/A"
    
    # SAFETY CHECK: Only do math if FinalSize is actually a number
    if ($OrigSize -gt 0 -and ($FinalSize -as [double])) {
        $FinalNum = [double]$FinalSize
        if ($FinalNum -gt 0) {
            $Reduction = [math]::Round((($OrigSize - $FinalNum) / $OrigSize) * 100, 2)
        }
    }
    
    $Script:Reductions += $Reduction
    $Script:Statuses += $Status
}

function Invoke-FFmpegEncode {
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [hashtable]$VideoParams,
        [hashtable]$AudioParams,
        [string]$PassLogFile = $null,
        [int]$Pass = 0
    )
    
    # Manually add quotes `"$Var`"
    $FFArgs = @(
        "-y",
        "-i", "`"$InputFile`""
    )
    $FFArgs += $Script:VsyncFlag.Split(' ')
    
    if ($Pass -gt 0) {
        $FFArgs += "-pass", $Pass, "-passlogfile", "`"$PassLogFile`""
    }
    
    # Video params
    $FFArgs += "-c:v", $Script:VideoCodec
    $FFArgs += "-pix_fmt", "yuv420p"
    
    if ($VideoParams.Bitrate) {
        $FFArgs += "-b:v", "$($VideoParams.Bitrate)k"
    }
    if ($VideoParams.CRF) {
        $FFArgs += "-crf", $VideoParams.CRF
    }
    if ($VideoParams.Preset) {
        $FFArgs += "-preset", $VideoParams.Preset
    }
    if ($VideoParams.Scale) {
        $FFArgs += "-vf", $VideoParams.Scale
    }
    
    # Audio params
    if ($Pass -eq 1) {
        $FFArgs += "-an" # No audio in pass 1
    } else {
        $FFArgs += "-c:a", "aac"
        $FFArgs += "-b:a", "$($AudioParams.Bitrate)k"
        
        # Add audio normalization if enabled
        if ($AudioParams.NormFilter) {
            $FFArgs += "-af", $AudioParams.NormFilter
        }
        
        $FFArgs += "-ac", "2"
    }
    
    if ($Pass -eq 1) {
        $FFArgs += "-f", "null", "NUL"
    } else {
        $FFArgs += "-map_metadata", "0"
        $FFArgs += "-movflags", "+faststart"
        $FFArgs += "`"$OutputFile`""
    }
    
    # Handle Log Path
    $LogPath = "$OutputFile.log"
    if ($OutputFile -eq "NUL") {
        $LogPath = Join-Path $Script:OUTPUT_DIR "ffmpeg_pass1_$PID.log"
    }
    
    # Execute
    $Process = Start-Process -FilePath $Script:FFmpeg -ArgumentList $FFArgs `
        -NoNewWindow -Wait -PassThru -RedirectStandardError $LogPath
    
    return $Process.ExitCode
}

function Invoke-RescueMode {
    param(
        [string]$InputFile,
        [string]$PartSuffix = ""
    )
    
    $FileName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $OutputFile = Join-Path $Script:OUTPUT_DIR "${FileName}${PartSuffix}_optimized.mp4"
    $TempFile = Join-Path $Script:OUTPUT_DIR "${FileName}${PartSuffix}_temp_$PID.mp4"
    $PassLog = Join-Path $Script:OUTPUT_DIR "rescue_pass_$PID"
    
    # Get audio normalization filter (two-pass if enabled)
    $AudioFilter = Get-AudioLoudnessFilter $InputFile
    
    Write-ColorOutput "  [Rescue] Bitrate constraints unsatisfiable. Engaging fallback..." "Yellow"
    
    $Duration = Get-Duration $InputFile
    $TargetSizeBytes = $TargetSizeMB * 1024 * 1024
    $OverheadBytes = $Script:OVERHEAD_KB * 1024
    
    $EstAudioBytes = $MinAudioBitrate * 1000 * $Duration / 8
    $TargetVideoBytes = $TargetSizeBytes - $EstAudioBytes - $OverheadBytes
    $VideoBitrateBps = $TargetVideoBytes * 8 / $Duration
    $CurrentVideoKbps = [math]::Floor($VideoBitrateBps / 1000)
    
    if ($CurrentVideoKbps -lt $MinVideoBitrate) {
        $CurrentVideoKbps = $MinVideoBitrate
    }
    
    # Phase 1: Try 1080p with retries
    $Retries = 0
    while ($Retries -lt $MaxRetries) {
        Write-ColorOutput "  [Rescue] Attempt $($Retries + 1) (1080p): ~${CurrentVideoKbps}kbps" "Gray"
        
        Show-Progress "Pass 1" "Analyzing" 0
        $ExitCode1 = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile "NUL" `
            -VideoParams @{ Bitrate=$CurrentVideoKbps; Preset=$Preset; Scale="scale='min(1920,iw)':-2" } `
            -AudioParams @{} -PassLogFile $PassLog -Pass 1
        Show-Progress "Pass 1" "Analyzing" 100
        Write-Host ""
        
        if ($ExitCode1 -ne 0) { break }
        
        Show-Progress "Pass 2" "Encoding" 0
        $ExitCode2 = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile $OutputFile `
            -VideoParams @{ Bitrate=$CurrentVideoKbps; Preset=$Preset; Scale="scale='min(1920,iw)':-2" } `
            -AudioParams @{ Bitrate=$MinAudioBitrate; NormFilter=$AudioFilter } -PassLogFile $PassLog -Pass 2
        Show-Progress "Pass 2" "Encoding" 100
        Write-Host ""
        
        if ($ExitCode2 -ne 0) { break }
        
        $FinalSize = Get-FileSizeMB $OutputFile
        
        if ($FinalSize -le $TargetSizeMB -and $FinalSize -gt 0) {
            Record-Summary $FileName (Get-FileSizeMB $InputFile) $FinalSize "Rescued (1080p)"
            Write-ColorOutput "  [Rescue] Success: $OutputFile (${FinalSize}MB) - Native Resolution" "Green"
            Remove-Item "${PassLog}*" -ErrorAction SilentlyContinue
            return $true
        }
        
        # Convergence
        $OvershootRatio = $FinalSize / $TargetSizeMB
        if ($OvershootRatio -lt 1.05) { $OvershootRatio = 1.05 }
        
        $CurrentVideoKbps = [math]::Floor($CurrentVideoKbps / $OvershootRatio)
        
        if ($CurrentVideoKbps -lt $MinVideoBitrate) {
            Write-ColorOutput "  [Rescue] Bitrate floor reached. Initiating 720p downscale." "Yellow"
            break
        }
        
        $Retries++
    }
    
    # Phase 2: Force 720p
    Write-ColorOutput "  [Rescue] Phase 2: Downscaling to 720p..." "Yellow"
    
    if ($CurrentVideoKbps -lt $MinVideoBitrate) {
        $CurrentVideoKbps = $MinVideoBitrate
    }
    
    $Retries = 0
    while ($Retries -lt $MaxRetries) {
        Write-ColorOutput "  [Rescue] 720p Attempt $($Retries + 1): ~${CurrentVideoKbps}kbps" "Gray"
        
        Show-Progress "Pass 1" "Analyzing" 0
        $ExitCode1 = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile "NUL" `
            -VideoParams @{ Bitrate=$CurrentVideoKbps; Preset=$Preset; Scale="scale='min(1280,iw)':-2" } `
            -AudioParams @{} -PassLogFile $PassLog -Pass 1
        Show-Progress "Pass 1" "Analyzing" 100
        Write-Host ""
        
        if ($ExitCode1 -ne 0) { break }
        
        Show-Progress "Pass 2" "Encoding" 0
        $ExitCode2 = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile $OutputFile `
            -VideoParams @{ Bitrate=$CurrentVideoKbps; Preset=$Preset; Scale="scale='min(1280,iw)':-2" } `
            -AudioParams @{ Bitrate=$MinAudioBitrate; NormFilter=$AudioFilter } -PassLogFile $PassLog -Pass 2
        Show-Progress "Pass 2" "Encoding" 100
        Write-Host ""
        
        if ($ExitCode2 -ne 0) { break }
        
        $FinalSize = Get-FileSizeMB $OutputFile
        
        if ($FinalSize -le $TargetSizeMB -and $FinalSize -gt 0) {
            Record-Summary $FileName (Get-FileSizeMB $InputFile) $FinalSize "Rescued (720p)"
            Write-ColorOutput "  [Rescue] Success: $OutputFile (${FinalSize}MB) - Downscaled to 720p" "Green"
            Remove-Item "${PassLog}*" -ErrorAction SilentlyContinue
            return $true
        }
        
        $OvershootRatio = $FinalSize / $TargetSizeMB
        if ($OvershootRatio -lt 1.05) { $OvershootRatio = 1.05 }
        
        $CurrentVideoKbps = [math]::Floor($CurrentVideoKbps / $OvershootRatio * 0.9)
        
        if ($CurrentVideoKbps -lt $MinVideoBitrate) {
            Write-ColorOutput "  [Rescue] 720p bitrate floor reached." "Yellow"
            break
        }
        
        $Retries++
    }
    
    # Phase 3: Last Resort CRF 28 @ 720p
    Write-ColorOutput "  [Rescue] Phase 3: Last resort CRF 28 @ 720p..." "Yellow"
    
    Show-Progress "CRF Pass" "Encoding" 0
    $ExitCodeCRF = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile $TempFile `
        -VideoParams @{ CRF=28; Preset=$Preset; Scale="scale='min(1280,iw)':-2" } `
        -AudioParams @{ Bitrate=64; NormFilter=$AudioFilter }
    Show-Progress "CRF Pass" "Encoding" 100
    Write-Host ""
    
    $CRFSizeMB = Get-FileSizeMB $TempFile
    
    if ($CRFSizeMB -le $TargetSizeMB -and $CRFSizeMB -gt 0) {
        Move-Item $TempFile $OutputFile -Force
        Record-Summary $FileName (Get-FileSizeMB $InputFile) $CRFSizeMB "Rescued (CRF)"
        Write-ColorOutput "  [Rescue] Success (CRF): $OutputFile (${CRFSizeMB}MB)" "Green"
        Remove-Item "${PassLog}*" -ErrorAction SilentlyContinue
        return $true
    }
    
    Write-ColorOutput "  [Rescue] All rescue attempts failed. Logs preserved in $Script:OUTPUT_DIR." "Red"
    Remove-Item $TempFile,"${PassLog}*" -ErrorAction SilentlyContinue
    return $false
}

function Split-VideoAtKeyframe {
    param(
        [string]$InputFile,
        [string]$PartSuffix = ""
    )
    
    $FileName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $Duration = Get-Duration $InputFile
    
    if ($Duration -eq 0) {
        Record-Summary "$FileName$PartSuffix" (Get-FileSizeMB $InputFile) "N/A" "Split Duration Fail"
        return $false
    }
    
    # Pre-flight check - calculate if mathematically possible
    $AbsoluteMinVideoBytes = $MinVideoBitrate * 1000 * $Duration / 8
    $AbsoluteMinAudioBytes = $MinAudioBitrate * 1000 * $Duration / 8
    $AbsoluteMinTotalMB = ($AbsoluteMinVideoBytes + $AbsoluteMinAudioBytes) / 1MB
    
    # If rescue might work, try that first
    if ($AbsoluteMinTotalMB -le $TargetSizeMB) {
        Write-ColorOutput "  Video might fit with rescue mode. Attempting rescue before split..." "Yellow"
        return Invoke-RescueMode $InputFile $PartSuffix
    }
    
    Write-ColorOutput "  Video too long for target size even at minimum bitrates. Must split." "Yellow"
    $HalfDuration = $Duration / 2
    
    Write-ColorOutput "Splitting $FileName at keyframe near ${HalfDuration}s..." "Cyan"
    $SplitPoint = Get-NearestKeyframe $InputFile $HalfDuration
    
    if ($SplitPoint -lt 0.5) {
        $SplitPoint = $HalfDuration
        Write-ColorOutput "  Using geometric center: ${SplitPoint}s" "Gray"
    } else {
        Write-ColorOutput "  Split point (keyframe): ${SplitPoint}s" "Gray"
    }
    
    $Part1Suffix = "${PartSuffix}_PART_1"
    $Part2Suffix = "${PartSuffix}_PART_2"
    $Part1File = Join-Path $Script:OUTPUT_DIR "${FileName}${Part1Suffix}_temp_$PID.mp4"
    $Part2File = Join-Path $Script:OUTPUT_DIR "${FileName}${Part2Suffix}_temp_$PID.mp4"
    
    # Split
    $Args1 = @("-y", "-i", $InputFile, "-t", $SplitPoint, "-c", "copy", "-avoid_negative_ts", "1", $Part1File)
    $Args2 = @("-y", "-i", $InputFile, "-ss", $SplitPoint, "-c", "copy", "-avoid_negative_ts", "1", $Part2File)
    
    $Proc1 = Start-Process -FilePath $Script:FFmpeg -ArgumentList $Args1 -NoNewWindow -Wait -PassThru -RedirectStandardError "$Part1File.log"
    $Proc2 = Start-Process -FilePath $Script:FFmpeg -ArgumentList $Args2 -NoNewWindow -Wait -PassThru -RedirectStandardError "$Part2File.log"
    
    if ($Proc1.ExitCode -ne 0 -or $Proc2.ExitCode -ne 0) {
        Write-ColorOutput "  Split failed. Check logs." "Red"
        Remove-Item $Part1File,$Part2File -ErrorAction SilentlyContinue
        Record-Summary "$FileName$PartSuffix" (Get-FileSizeMB $InputFile) "N/A" "Split Fail"
        return $false
    }
    
    if ((Get-FileSizeMB $Part1File) -eq 0 -or (Get-FileSizeMB $Part2File) -eq 0) {
        Write-ColorOutput "  Split produced zero-byte artifacts." "Red"
        Remove-Item $Part1File,$Part2File -ErrorAction SilentlyContinue
        Record-Summary "$FileName$PartSuffix" (Get-FileSizeMB $InputFile) "N/A" "Split Fail"
        return $false
    }
    
    # Recursively optimize
    $Result1 = Optimize-Video $Part1File $Part1Suffix
    $Result2 = Optimize-Video $Part2File $Part2Suffix
    
    Remove-Item $Part1File,$Part2File -ErrorAction SilentlyContinue
    
    if ($Result1 -and $Result2) {
        Record-Summary "$FileName$PartSuffix" (Get-FileSizeMB $InputFile) "N/A" "Split"
        return $true
    }
    
    return $false
}

function Optimize-Video {
    param(
        [string]$InputFile,
        [string]$PartSuffix = ""
    )
    
    $FileName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $OutputFile = Join-Path $Script:OUTPUT_DIR "${FileName}${PartSuffix}_optimized.mp4"
    $TempFile = Join-Path $Script:OUTPUT_DIR "${FileName}${PartSuffix}_temp_$PID.mp4"
    $PassLog = Join-Path $Script:OUTPUT_DIR "ffmpeg2pass_$PID"
    
    # Get audio normalization filter (two-pass if enabled)
    $AudioFilter = Get-AudioLoudnessFilter $InputFile
    
    $OrigSizeMB = Get-FileSizeMB $InputFile
    
    if ($OrigSizeMB -eq 0) {
        Write-ColorOutput "Skipping zero-byte input: $InputFile" "Yellow"
        Record-Summary "$FileName$PartSuffix" 0 "N/A" "Empty Input"
        return $false
    }
    
    Write-ColorOutput "Processing: $InputFile (Original: ${OrigSizeMB}MB)" "Cyan"
    
    if ($OrigSizeMB -lt $Script:MAX_SIZE_MB) {
        Copy-Item $InputFile $OutputFile -Force
        Record-Summary "$FileName$PartSuffix" $OrigSizeMB $OrigSizeMB "Copied"
        Write-ColorOutput "Copied: $OutputFile" "Green"
        return $true
    }
    
    $Duration = Get-Duration $InputFile
    if ($Duration -eq 0) {
        Record-Summary "$FileName$PartSuffix" $OrigSizeMB "N/A" "Duration Fail"
        return $false
    }
    
    # Bitrate calculation
    $AudioBitrateKbps = $Script:INITIAL_AUDIO_BITRATE_KBPS
    $TargetSizeBytes = $TargetSizeMB * 1024 * 1024
    $OverheadBytes = $Script:OVERHEAD_KB * 1024
    
    $EstAudioBytes = $AudioBitrateKbps * 1000 * $Duration / 8
    $TargetVideoBytes = $TargetSizeBytes - $EstAudioBytes - $OverheadBytes
    $VideoBitrateBps = $TargetVideoBytes * 8 / $Duration
    $VideoBitrateBps = [math]::Floor($VideoBitrateBps)
    
    if ($VideoBitrateBps -gt ($Script:MAX_VIDEO_BITRATE_KBPS * 1000)) {
        $VideoBitrateBps = $Script:MAX_VIDEO_BITRATE_KBPS * 1000
    }
    
    if ($VideoBitrateBps -lt ($MinVideoBitrate * 1000)) {
        $VideoBitrateBps = $MinVideoBitrate * 1000
    }
    
    $CurrentVideoKbps = [math]::Floor($VideoBitrateBps / 1000)
    
    $Retries = 0
    
    while ($Retries -lt $MaxRetries) {
        Write-ColorOutput "Attempt $($Retries + 1): Video ~${CurrentVideoKbps}kbps, Audio ${AudioBitrateKbps}kbps" "Gray"
        
        if ($CurrentVideoKbps -lt $MinVideoBitrate) {
            $CurrentVideoKbps = $MinVideoBitrate
        }
        
        # Pass 1
        Show-Progress "Pass 1" "Analyzing" 0
        $ExitCode1 = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile "NUL" `
            -VideoParams @{ Bitrate=$CurrentVideoKbps; Preset=$Preset; Scale="scale='min(1920,iw)':-2" } `
            -AudioParams @{} -PassLogFile $PassLog -Pass 1
        Show-Progress "Pass 1" "Analyzing" 100
        Write-Host ""
        
        if ($ExitCode1 -ne 0) {
            Write-ColorOutput "Encoding failed. Check logs." "Red"
            Remove-Item $TempFile,"${PassLog}*" -ErrorAction SilentlyContinue
            Record-Summary "$FileName$PartSuffix" $OrigSizeMB "N/A" "Encode Fail"
            return $false
        }
        
        # Pass 2
        Show-Progress "Pass 2" "Encoding" 0
        $ExitCode2 = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile $TempFile `
            -VideoParams @{ Bitrate=$CurrentVideoKbps; Preset=$Preset; Scale="scale='min(1920,iw)':-2" } `
            -AudioParams @{ Bitrate=$AudioBitrateKbps; NormFilter=$AudioFilter } -PassLogFile $PassLog -Pass 2
        Show-Progress "Pass 2" "Encoding" 100
        Write-Host ""
        
        if ($ExitCode2 -ne 0) {
            Write-ColorOutput "Encoding failed. Check logs." "Red"
            Remove-Item $TempFile,"${PassLog}*" -ErrorAction SilentlyContinue
            Record-Summary "$FileName$PartSuffix" $OrigSizeMB "N/A" "Encode Fail"
            return $false
        }
        
        $FinalSizeMB = Get-FileSizeMB $TempFile
        Write-ColorOutput "  Result: ${FinalSizeMB}MB" "Gray"
        
        if ($FinalSizeMB -le $Script:MAX_SIZE_MB) {
            Move-Item $TempFile $OutputFile -Force
            Record-Summary "$FileName$PartSuffix" $OrigSizeMB $FinalSizeMB "Optimized"
            Write-ColorOutput "Success: $OutputFile (${FinalSizeMB}MB)" "Green"
            Remove-Item "${PassLog}*" -ErrorAction SilentlyContinue
            return $true
        }
        
        $Retries++
        if ($Retries -lt $MaxRetries) {
            Write-ColorOutput "  Result exceeds target (${FinalSizeMB}MB > $($Script:MAX_SIZE_MB)MB). Recalculating..." "Yellow"
            
            $OvershootRatio = $FinalSizeMB / $Script:MAX_SIZE_MB
            $CurrentVideoKbps = [math]::Floor($CurrentVideoKbps / $OvershootRatio)
            
            if ($CurrentVideoKbps -lt $MinVideoBitrate) {
                $CurrentVideoKbps = $MinVideoBitrate
                if ($AudioBitrateKbps -gt $MinAudioBitrate) {
                    $AudioBitrateKbps = $AudioBitrateKbps - 32
                    if ($AudioBitrateKbps -lt $MinAudioBitrate) {
                        $AudioBitrateKbps = $MinAudioBitrate
                    }
                    Write-ColorOutput "  Video at floor, reducing audio to ${AudioBitrateKbps}kbps..." "Yellow"
                } else {
                    Write-ColorOutput "  All bitrates at floor. Initiating fallback..." "Yellow"
                    break
                }
            }
        } else {
            Write-ColorOutput "Max retries exhausted. Initiating fallback..." "Yellow"
            break
        }
        
        Remove-Item $TempFile -ErrorAction SilentlyContinue
    }
    
    # CRF Rescue
    Write-ColorOutput "  [Info] Attempting CRF 28 rescue before splitting..." "Yellow"
    
    Show-Progress "CRF Pass" "Encoding" 0
    $ExitCodeCRF = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile $TempFile `
        -VideoParams @{ CRF=28; Preset=$Preset; Scale="scale='min(1920,iw)':-2" } `
        -AudioParams @{ Bitrate=64; NormFilter=$AudioFilter }
    Show-Progress "CRF Pass" "Encoding" 100
    Write-Host ""
    
    $CRFSizeMB = Get-FileSizeMB $TempFile
    
    if ($CRFSizeMB -le $Script:MAX_SIZE_MB -and $CRFSizeMB -gt 0) {
        Move-Item $TempFile $OutputFile -Force
        Record-Summary "$FileName$PartSuffix" $OrigSizeMB $CRFSizeMB "Rescued (CRF)"
        Write-ColorOutput "Success (CRF Rescue): $OutputFile (${CRFSizeMB}MB)" "Green"
        Remove-Item "${PassLog}*" -ErrorAction SilentlyContinue
        return $true
    }
    
    Write-ColorOutput "  [Info] CRF pass failed (${CRFSizeMB}MB). Proceeding to split..." "Yellow"
    Remove-Item $TempFile,"${PassLog}*" -ErrorAction SilentlyContinue
    
    return Split-VideoAtKeyframe $InputFile $PartSuffix
}

# --- Main Execution ---

Write-ColorOutput "Initializing optimization pipeline..." "Cyan"

# Setup
if (-not (Test-Path $Script:OUTPUT_DIR)) {
    New-Item -ItemType Directory -Path $Script:OUTPUT_DIR | Out-Null
}

$Script:FFmpeg = Get-FFmpegPath
$Script:FFprobe = Get-FFprobePath

if (-not $Script:FFprobe) {
    Write-ColorOutput "WARNING: ffprobe not found. Some features may be limited." "Yellow"
}

# Detect codec
try {
    $EncoderList = & $Script:FFmpeg -encoders 2>&1 | Out-String
    if ($EncoderList -match "libx265") {
        $Script:VideoCodec = "libx265"
    } else {
        $Script:VideoCodec = "libx264"
        Write-ColorOutput "libx265 not available, using libx264" "Yellow"
    }
} catch {
    # Fallback to libx264 if detection fails
    $Script:VideoCodec = "libx264"
    Write-ColorOutput "Codec detection failed, defaulting to libx264" "Yellow"
}

# Detect vsync flag
try {
    $FFmpegVersion = & $Script:FFmpeg -version 2>&1 | Select-Object -First 1 | Out-String
    if ($FFmpegVersion -match "version [5-9]\." -or $FFmpegVersion -match "version [1-9][0-9]\.") {
        $Script:VsyncFlag = "-fps_mode cfr"
    } else {
        $Script:VsyncFlag = "-vsync 1"
    }
} catch {
    # Fallback to legacy flag
    $Script:VsyncFlag = "-vsync 1"
}

$AudioNormStatus = if ($NormalizeAudio) { "Enabled (Two-Pass)" } else { "Disabled" }
Write-ColorOutput "Configuration: Codec=$($Script:VideoCodec) | Vsync=$($Script:VsyncFlag) | Audio Normalization=$AudioNormStatus" "Gray"

# Gather files
if ($Files.Count -eq 0) {
    Write-ColorOutput "No files specified. Scanning current directory for *.mp4..." "Cyan"
    $Files = Get-ChildItem -Path $PSScriptRoot -Filter "*.mp4" | Select-Object -ExpandProperty FullName
}

# Filter out already-optimized files and expand folders
$FilesToProcess = @()
foreach ($File in $Files) {
    if (Test-Path $File -PathType Container) {
        Write-ColorOutput "Folder detected: $File - Scanning for MP4s..." "Cyan"
        $FolderFiles = Get-ChildItem -Path $File -Filter "*.mp4" -Recurse | Select-Object -ExpandProperty FullName
        foreach ($SubFile in $FolderFiles) {
            if ($SubFile -notmatch "_optimized\.mp4$") {
                $FilesToProcess += $SubFile
            }
        }
    } elseif ($File -notmatch "_optimized\.mp4$") {
        $FilesToProcess += $File
    }
}

if ($FilesToProcess.Count -eq 0) {
    Write-ColorOutput "No valid .mp4 files found to process." "Red"
    Read-Host "Press Enter to exit"
    exit 0
}

Write-ColorOutput "Found $($FilesToProcess.Count) file(s) to process.`n" "Green"

# Process all files
foreach ($File in $FilesToProcess) {
    if (-not (Test-Path $File)) {
        Write-ColorOutput "File not found: $File" "Red"
        continue
    }
    
    $null = Optimize-Video $File
    Write-Host "" # Spacing
}

# Generate Summary Report
Write-ColorOutput "`nWriting summary to $Script:SUMMARY_FILE..." "Cyan"

$SummaryContent = @()
$SummaryContent += "{0,-40} {1,-12} {2,-12} {3,-12} {4,-15}" -f "File", "Orig Size", "Final Size", "Reduction %", "Status"
$SummaryContent += "-" * 91

for ($i = 0; $i -lt $Script:ProcessedFiles.Count; $i++) {
    $SummaryContent += "{0,-40} {1,-12} {2,-12} {3,-12} {4,-15}" -f `
        $Script:ProcessedFiles[$i].Substring(0, [math]::Min(40, $Script:ProcessedFiles[$i].Length)),
        $Script:OriginalSizes[$i],
        $Script:FinalSizes[$i],
        $Script:Reductions[$i],
        $Script:Statuses[$i]
}

$SummaryContent | Out-File $Script:SUMMARY_FILE -Encoding UTF8

# Cleanup
if (-not $NoCleanup) {
    Write-ColorOutput "Cleaning up temporary artifacts..." "Gray"
    Get-ChildItem -Path $Script:OUTPUT_DIR -Filter "ffmpeg2pass*" | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $Script:OUTPUT_DIR -Filter "*_temp_*.mp4" | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $Script:OUTPUT_DIR -Filter "*_loudnorm_*.json" | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $Script:OUTPUT_DIR -Filter "*.log" | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-ColorOutput "`nOptimization complete! Summary in $Script:SUMMARY_FILE" "Green"
Write-ColorOutput "Optimized files are in: $Script:OUTPUT_DIR" "Cyan"

Read-Host "`nPress Enter to exit"