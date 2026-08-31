<#
.SYNOPSIS
    FFmpeg Shrinkwrap - Constraint-Driven MP4 Optimizer for Discord
    Full-featured Windows port with rescue modes, splitting, and adaptive encoding

.DESCRIPTION
    Automatically compresses videos to fit Discord's 20MB limit using intelligent
    fallback strategies: 2-pass encoding -> CRF rescue -> 720p downscale -> split at keyframes

.PARAMETER Files
    Video files to process. If none specified, processes common video files
    (mp4/mkv/mov/avi/webm/m4v/flv) in the current directory. Output is always .mp4.

.PARAMETER Encoder
    Video encoder selection. Default: auto
      auto              Software detection (libx265, else libx264) + 2-pass (default; unchanged)
      hw                Probe the GPU hierarchy (AV1 -> HEVC via AMF/NVENC/QSV/VideoToolbox),
                        falling back to software if none are functional
      <encoder name>    Force a specific encoder (e.g. hevc_nvenc, av1_amf, h264_qsv);
                        functionally validated, falls back to software if it fails the probe
    Hardware encodes are single-pass capped VBR. Note: hardware AV1/HEVC may not play in
    Discord's inline player for all viewers, and at the size cap usually compress worse
    than libx265 2-pass.

.PARAMETER Preset
    FFmpeg x265 preset (ultrafast/superfast/veryfast/faster/fast/medium/slow/slower/veryslow)
    Default: slow

.PARAMETER TargetSizeMB
    Target file size in MB. Default: 19.8

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

.PARAMETER Mono
    Downmix audio to a single channel (-ac 1). Frees budget on voice-only / long clips.

.PARAMETER NoAudio
    Remove audio entirely (-an). Frees the whole size budget for video. Overrides -NormalizeAudio
    and -Mono (there is no audio to process).

.PARAMETER OutputDir
    Custom output directory for compressed videos. Default: .\optimized

.PARAMETER Config
    Launch the interactive setup wizard: choose a default encoder, write shrinkwrap.conf,
    then exit without processing any files. Re-run anytime to reconfigure. Requires an
    interactive terminal. The saved preference drives the default encoder when -Encoder is
    not passed; -Encoder always overrides it for that run.

.EXAMPLE
    .\shrinkwrap.ps1 -Config
    Run the setup wizard to pick and persist a default encoder, then exit

.EXAMPLE
    .\shrinkwrap.ps1
    Process all video files in current directory with default 19.8MB target

.EXAMPLE
    .\shrinkwrap.ps1 -Files "gameplay.mp4","clip.mp4"
    Process specific files

.EXAMPLE
    .\shrinkwrap.ps1 -TargetSizeMB 49 -Preset medium -Files "clip.mp4"
    Compress for a 50MB Discord Nitro Basic upload

.EXAMPLE
    .\shrinkwrap.ps1 -Encoder hw -Files "clip.mp4"
    Use GPU hardware acceleration (auto-probes best working GPU encoder)

.EXAMPLE
    .\shrinkwrap.ps1 -Encoder hevc_nvenc -Files "clip.mp4"
    Force NVIDIA NVENC HEVC hardware encoder

.EXAMPLE
    .\shrinkwrap.ps1 -NormalizeAudio -Mono -Files "podcast.mp4"
    Normalize loudness (-16 LUFS) and downmix to mono to maximize video budget

.EXAMPLE
    .\shrinkwrap.ps1 -NoAudio -Files "clip.mp4"
    Strip audio completely (-an) to dedicate 100% of bitrate to video
#>

# PositionalBinding=$false plus an explicit Position=0 on $Files is load-bearing: a parameter
# declared with ValueFromRemainingArguments is skipped when PowerShell auto-numbers positions,
# so under default binding the first positional argument lands on $Encoder (the second on
# $Preset, the third throws on $TargetSizeMB). That silently swallowed drag-and-drop paths.
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$Files,

    [string]$Encoder = "auto",
    [string]$Preset = "slow",
    [double]$TargetSizeMB = 19.8,
    [int]$MinVideoBitrate = 500,
    [int]$MinAudioBitrate = 64,
    [int]$MaxRetries = 3,
    [string]$OutputDir = $null,
    [switch]$NoCleanup,
    [switch]$NormalizeAudio,
    [switch]$Mono,
    [switch]$NoAudio,
    [switch]$Config
)

$ErrorActionPreference = "Continue" # Changed from "Stop" to handle FFmpeg stderr gracefully
$ProgressPreference = "SilentlyContinue" # Disable built-in progress for speed

# --- Configuration Constants ---
$Script:MAX_SIZE_MB = 20.0
$Script:INITIAL_AUDIO_BITRATE_KBPS = 192
$Script:CRF_RESCUE_VALUE = 28
$Script:OVERHEAD_KB = 200
$Script:MAX_VIDEO_BITRATE_KBPS = 50000
$Script:OUTPUT_DIR = Join-Path $PSScriptRoot "optimized"
$Script:SUMMARY_FILE = "optimization_summary.txt"
$Script:AudioChannels = if ($Mono) { 1 } else { 2 } # Stereo by default; -Mono downmixes
$Script:InputExtensions = @('.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.flv')

# Hardware hierarchy probed for -Encoder hw (AV1-hw -> HEVC-hw). h264_* hardware is
# intentionally absent: reachable only by explicit selection, never auto-ranked above
# libx265. If none pass, we fall back to the software default (libx265-or-libx264).
$Script:HwHierarchy = @('av1_amf','av1_nvenc','av1_qsv','hevc_amf','hevc_nvenc','hevc_qsv','hevc_videotoolbox')

# Persisted-preference defaults (used when shrinkwrap.conf is absent or a key is missing).
# $Script:HwHierarchy doubles as the default hardware_order.
$Script:DEFAULT_MODE = 'software'
$Script:DEFAULT_SOFTWARE_ORDER = @('libx265','libx264')
$Script:CONFIG_NAME = 'shrinkwrap.conf'
# Track whether -Encoder was user-supplied (distinguishes a config-driven default from -Encoder auto).
$Script:EncoderExplicit = $PSBoundParameters.ContainsKey('Encoder')

# --- UI: UTF-8 output + glyph table (so the banner / checkmarks render) + run stopwatch ---
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Script:G = @{
    Ok    = [string][char]0x2713
    Fail  = [string][char]0x2717
    Arrow = [string][char]0x25BA
    Box   = [char]::ConvertFromUtf32(0x1F4E6)
    HLine = [string][char]0x2500
    Heavy = [string][char]0x2550
}
$Script:Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# --- Audio Normalization Cache ---
$Script:AudioNormCache = @{}

# --- Reporting Structures ---
# One record (pscustomobject) per file instead of five parallel arrays, so columns
# can never silently desync -- and it gives us a CSV export for free.
$Script:Report = [System.Collections.Generic.List[object]]::new()

# --- Utility Functions ---

function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Write-Rule {
    param([string]$Glyph = $Script:G.HLine, [int]$Width = 60)
    Write-Host ($Glyph * $Width) -ForegroundColor DarkGray
}

function Write-Banner {
    param([string]$Target, [string]$Codec, [string]$Preset, [string]$AudioMode)
    Write-Host ""
    Write-Host ("{0} " -f $Script:G.Box) -ForegroundColor Cyan -NoNewline
    Write-Host "ffmpeg-shrinkwrap" -ForegroundColor White -NoNewline
    Write-Host "  Discord video compressor" -ForegroundColor Gray
    Write-Host ("  target <= {0} MB  |  codec {1}  |  preset {2}  |  audio {3}" -f $Target, $Codec, $Preset, $AudioMode) -ForegroundColor DarkGray
    Write-Rule $Script:G.Heavy
}

function Write-FileHeader {
    param([int]$Index, [int]$Total, [string]$Name)
    Write-Host ""
    Write-Host ("{0} [{1}/{2}] " -f $Script:G.Arrow, $Index, $Total) -ForegroundColor Cyan -NoNewline
    Write-Host $Name -ForegroundColor White
}

function Write-Tally {
    param([double]$TotalIn, [double]$TotalOut, [string]$Elapsed)
    $nOpt = 0; $nCopy = 0; $nRescue = 0; $nSplit = 0; $nFail = 0
    foreach ($r in $Script:Report) {
        switch -Wildcard ($r.Status) {
            'Optimized'   { $nOpt++;    break }
            'Copied'      { $nCopy++;   break }
            'Rescued*'    { $nRescue++; break }
            'Split'       { $nSplit++;  break }
            '*Fail*'      { $nFail++;   break }
            'Empty Input' { $nFail++;   break }
        }
    }
    # Format numbers invariantly (period decimals) so the tally matches Bash regardless of locale.
    $Inv = [System.Globalization.CultureInfo]::InvariantCulture
    $pct = if ($TotalIn -gt 0) { [math]::Round((($TotalIn - $TotalOut) / $TotalIn) * 100, 1) } else { 0 }
    $inStr  = ([math]::Round($TotalIn, 2)).ToString($Inv)
    $outStr = ([math]::Round($TotalOut, 2)).ToString($Inv)
    $pctStr = ([double]$pct).ToString($Inv)
    Write-Host ""
    Write-Rule $Script:G.Heavy
    Write-Host ("{0} Done" -f $Script:G.Ok) -ForegroundColor Green -NoNewline
    Write-Host " in $Elapsed"
    Write-Host ("  {0} {1} optimized, {2} copied, {3} rescued, {4} split, {5} {6} failed" -f `
        $Script:G.Ok, $nOpt, $nCopy, $nRescue, $nSplit, $Script:G.Fail, $nFail) -ForegroundColor Gray
    Write-Host ("  Total: {0} MB -> {1} MB  ({2}% smaller)" -f $inStr, $outStr, $pctStr) -ForegroundColor Cyan
    Write-Rule $Script:G.Heavy
}

function Wait-ForExit {
    # Pause for the user, but skip silently when non-interactive (CI / scheduled task)
    # so the script never hangs on Read-Host.
    param([string]$Message = "Press Enter to exit")
    if ([Environment]::UserInteractive) {
        Read-Host $Message | Out-Null
    }
}

function Invoke-Cleanup {
    # Remove temp/log artifacts. Runs on normal completion AND from the finally block on
    # Ctrl+C, so an interrupted run doesn't leave partial files behind. Respects -NoCleanup.
    if ($NoCleanup) { return }
    if (-not (Test-Path $Script:OUTPUT_DIR)) { return }
    foreach ($Pattern in @("*_temp_*.mp4", "ffmpeg2pass*", "rescue_pass*", "ffmpeg_pass1_*", "*_loudnorm_*.json", "*.log")) {
        Get-ChildItem -Path $Script:OUTPUT_DIR -Filter $Pattern -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
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
    Wait-ForExit
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

    # Try container (format) duration first, then the video stream duration as a fallback.
    # Guard against "N/A" / empty / non-numeric so [double] never throws, and parse
    # invariantly so a comma-decimal locale can't corrupt the value.
    foreach ($Entry in @("format=duration", "stream=duration")) {
        $ProbeArgs = @("-v", "error")
        if ($Entry -like "stream=*") { $ProbeArgs += @("-select_streams", "v:0") }
        $ProbeArgs += @("-show_entries", $Entry, "-of", "default=noprint_wrappers=1:nokey=1", $FilePath)

        $Result = (& $Script:FFprobe @ProbeArgs 2>$null | Select-Object -First 1)
        if ($Result) {
            $Result = "$Result".Trim()
            $Parsed = 0.0
            if ($Result -ne "N/A" -and
                [double]::TryParse($Result, [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Parsed) -and
                $Parsed -gt 0) {
                return $Parsed
            }
        }
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
    
    # Scan packet flags for the last keyframe (flag "K") before the target time.
    $PacketsRaw = & $Script:FFprobe -v error -select_streams v:0 `
        -show_packets -show_entries packet=pts_time,flags -of csv=p=0 $FilePath 2>$null

    $LastKeyframe = $null
    foreach ($Line in $PacketsRaw) {
        $Parts = $Line -split ','
        if ($Parts.Count -lt 2) { continue }
        if ($Parts[0] -eq 'N/A') { continue }
        # The flags field contains "K" for keyframe packets (e.g. "K__").
        if ($Parts[1] -match 'K') {
            $Time = [double]$Parts[0]
            if ($Time -gt 0 -and $Time -lt $TargetTime) {
                $LastKeyframe = $Time
            }
        }
    }

    if ($null -ne $LastKeyframe) {
        return $LastKeyframe # Last keyframe before target
    }
    return $TargetTime # Fallback to target time
}

# Bytes to reserve for audio in the size budget: 0 when audio is stripped (-NoAudio), else kbps*dur.
function Get-AudioBudgetBytes {
    param([double]$Kbps, [double]$Duration)
    if ($NoAudio) { return 0 }
    return $Kbps * 1000 * $Duration / 8
}

function Get-AudioLoudnessFilter {
    param([string]$InputFile)

    if (-not $NormalizeAudio -or $NoAudio) {
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

        # loudnorm prints its JSON summary to stderr; capture it to the temp file.
        & $Script:FFmpeg @AnalysisArgs 2> $JsonFile | Out-Null

        if (-not (Test-Path $JsonFile) -or (Get-Item $JsonFile).Length -eq 0) {
            Write-ColorOutput "  [Warning] Audio analysis failed (empty log), falling back to single-pass" "Yellow"
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
    # The PS port doesn't parse ffmpeg's per-frame progress, so instead of a misleading
    # 0%->100% jump we print an honest status line: "Status..." when work starts and
    # " done" when it finishes (the paired call passes PercentComplete=100).
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete
    )

    if ($PercentComplete -ge 100) {
        Write-Host " done" -NoNewline
    } else {
        Write-Host "  $Status..." -NoNewline
    }
}

function Record-Summary {
    param(
        [string]$FileName,
        [double]$OrigSize,
        [string]$FinalSize,
        [string]$Status
    )
    
    $Inv = [System.Globalization.CultureInfo]::InvariantCulture
    $Reduction = "N/A"

    # SAFETY CHECK: Only do math if FinalSize is actually a number
    if ($OrigSize -gt 0 -and ($FinalSize -as [double])) {
        $FinalNum = [double]$FinalSize
        if ($FinalNum -gt 0) {
            $Reduction = [math]::Round((($OrigSize - $FinalNum) / $OrigSize) * 100, 2).ToString($Inv)
        }
    }

    # One record per file -> columns can never desync. Numbers are stored as
    # invariant-culture strings so the report never mixes "9.3" and "9,3" by locale.
    $Script:Report.Add([pscustomobject]@{
        File         = $FileName
        OrigSizeMB   = $OrigSize.ToString($Inv)
        FinalSizeMB  = $FinalSize
        ReductionPct = $Reduction
        Status       = $Status
    })
}

# --- Hardware-encoder support (opt-in via -Encoder) ---------------------------
# Software (libx264/libx265) drives the unchanged 2-pass path; every other family is
# single-pass hardware (vendor rate-control + presets, no file-based 2-pass).
function Get-CodecFamily {
    param([string]$Encoder)
    switch -Wildcard ($Encoder) {
        '*_amf'          { return 'amf' }
        '*_nvenc'        { return 'nvenc' }
        '*_qsv'          { return 'qsv' }
        '*_videotoolbox' { return 'videotoolbox' }
        default          { return 'software' }
    }
}

# --- Preset normalization ------------------------------------------------------
# Any preset the user types (an x264/x265 name OR another vendor's token) is normalized to a
# token valid for whichever encoder is actually selected, so the run never breaks on a syntax
# mismatch. The model is three speed tiers (fast|medium|slow); cross-vendor input is warned
# about once (see Warn-PresetMismatch) but still honored.

# Single source of truth for every recognized preset name: returns @{ Vendor; Tier }.
#   Vendor: x264 | amf | nvenc | unknown      Tier: fast | medium | slow
# An unrecognized token defaults to the slow tier (the project default).
function Get-PresetInfo {
    param([string]$Name)
    switch ($Name) {
        { $_ -in 'ultrafast','superfast','veryfast','faster','fast' } { return @{ Vendor='x264'; Tier='fast' } }
        'medium'   { return @{ Vendor='x264'; Tier='medium' } }
        { $_ -in 'slow','slower','veryslow','placebo' }               { return @{ Vendor='x264'; Tier='slow' } }
        'speed'    { return @{ Vendor='amf'; Tier='fast' } }
        'balanced' { return @{ Vendor='amf'; Tier='medium' } }
        'quality'  { return @{ Vendor='amf'; Tier='slow' } }
        { $_ -in 'p1','p2','p3' } { return @{ Vendor='nvenc'; Tier='fast' } }
        { $_ -in 'p4','p5' }      { return @{ Vendor='nvenc'; Tier='medium' } }
        { $_ -in 'p6','p7' }      { return @{ Vendor='nvenc'; Tier='slow' } }
        default    { return @{ Vendor='unknown'; Tier='slow' } }
    }
}

# Translate a slow|medium|fast tier into the family's native preset/quality token.
function Get-HwPreset {
    param([string]$Family, [string]$Tier)
    switch ($Family) {
        'amf'   { switch ($Tier) { 'slow' { 'quality' } 'medium' { 'balanced' } 'fast' { 'speed' } } }
        'nvenc' { switch ($Tier) { 'slow' { 'p7' }      'medium' { 'p5' }       'fast' { 'p3' } } }
        'qsv'   { return $Tier }          # qsv preset names are slow/medium/fast/... already
        default { return '' }             # videotoolbox: no preset knob
    }
}

# True when preset $Preset (vendor $Vendor) is already valid for $Family (verbatim pass-through,
# preserving full x264/qsv/nvenc granularity). amf is intentionally absent: its tokens round-trip
# the tier map, so translating them yields the identical token anyway.
function Test-PresetNative {
    param([string]$Family, [string]$Preset, [string]$Vendor)
    switch ($Family) {
        'software' { return ($Vendor -eq 'x264') }
        'nvenc'    { return ($Vendor -eq 'nvenc') }
        'qsv'      { return ($Preset -in 'veryfast','faster','fast','medium','slow','slower','veryslow') }
        default    { return $false }      # amf (round-trips) + videotoolbox (no preset knob)
    }
}

# Resolve any preset string to a token valid for $Family: verbatim if native, else translated
# via its speed tier (Get-PresetInfo already supplies the slow-tier default for unknown tokens).
function Resolve-PresetToken {
    param([string]$Family, [string]$Preset)
    $info = Get-PresetInfo $Preset
    if (Test-PresetNative -Family $Family -Preset $Preset -Vendor $info.Vendor) { return $Preset }
    if ($Family -eq 'software') { return $info.Tier }
    return (Get-HwPreset -Family $Family -Tier $info.Tier)
}

# Warn once if the user's preset isn't native to the selected family, then show the per-encoder
# guide. x264/x265 names are the universal input and never warn (so the default 'slow' is silent).
function Warn-PresetMismatch {
    param([string]$Family, [string]$Raw, [string]$Resolved)
    if ($Family -eq 'videotoolbox') { return }
    $vendor = (Get-PresetInfo $Raw).Vendor
    if ($vendor -eq 'x264' -or $vendor -eq $Family) { return }
    if ($vendor -eq 'unknown') {
        Write-ColorOutput "  [Preset] Unrecognized preset '$Raw'; using '$Resolved' for $Family." "Yellow"
    } else {
        Write-ColorOutput "  [Preset] '$Raw' is a $vendor preset but the active encoder is $Family; using '$Resolved'." "Yellow"
    }
    Write-ColorOutput "  Preset guide (any of these works; it is mapped to the active encoder):" "DarkGray"
    Write-ColorOutput "    software (libx264/libx265): ultrafast superfast veryfast faster fast medium slow slower veryslow placebo" "DarkGray"
    Write-ColorOutput "    amf:   quality(slow) balanced(medium) speed(fast)" "DarkGray"
    Write-ColorOutput "    nvenc: p7/p6(slow) p5/p4(medium) p3/p2/p1(fast)" "DarkGray"
    Write-ColorOutput "    qsv:   veryfast faster fast medium slow slower veryslow" "DarkGray"
}

# Build the family-correct single-pass video rate-control + preset argument array.
#   Mode = bitrate -> capped VBR at the target bitrate X, maxrate X, bufsize 2X
#   Mode = cq      -> constant-quality rescue (replaces -crf 28), capped by maxrate
function Build-HwVideoArgs {
    param([string]$Family, [string]$Mode, [int]$Bitrate, [int]$MaxRate)
    $BufSize = $MaxRate * 2
    $vp = Resolve-PresetToken -Family $Family -Preset $Preset   # valid for this family, whatever was typed
    $a = @()
    switch ($Family) {
        'nvenc' {
            $a += '-rc','vbr','-multipass','fullres'
            if ($vp) { $a += '-preset',$vp }
            if ($Mode -eq 'cq') { $a += '-cq',"$($Script:CRF_RESCUE_VALUE)",'-b:v','0','-maxrate',"${MaxRate}k",'-bufsize',"${BufSize}k" }
            else                { $a += '-b:v',"${Bitrate}k",'-maxrate',"${MaxRate}k",'-bufsize',"${BufSize}k" }
        }
        'amf' {
            $a += '-rc','vbr_peak'
            if ($vp) { $a += '-quality',$vp }
            # AMF has no stable CQ flag across builds -> capped VBR; cq mode targets the budget.
            if ($Mode -eq 'cq') { $a += '-b:v',"${MaxRate}k",'-maxrate',"${MaxRate}k",'-bufsize',"${BufSize}k" }
            else                { $a += '-b:v',"${Bitrate}k",'-maxrate',"${MaxRate}k",'-bufsize',"${BufSize}k" }
        }
        'qsv' {
            if ($vp) { $a += '-preset',$vp }
            if ($Mode -eq 'cq') { $a += '-global_quality',"$($Script:CRF_RESCUE_VALUE)",'-maxrate',"${MaxRate}k",'-bufsize',"${BufSize}k" }
            else                { $a += '-b:v',"${Bitrate}k",'-maxrate',"${MaxRate}k",'-bufsize',"${BufSize}k" }
        }
        'videotoolbox' {
            # No preset knob and no stable CQ flag -> capped VBR; cq mode targets the budget.
            if ($Mode -eq 'cq') { $a += '-b:v',"${MaxRate}k",'-maxrate',"${MaxRate}k",'-bufsize',"${BufSize}k" }
            else                { $a += '-b:v',"${Bitrate}k",'-maxrate',"${MaxRate}k",'-bufsize',"${BufSize}k" }
        }
    }
    return ,$a   # leading comma: always return an array, never unroll a single element
}

# Functional probe: a real 1-frame encode with the exact RC template we will use.
# Returns $true only if the encoder is compiled in AND actually works on this machine
# (compiled-in != usable for hardware, so the name grep alone is not trustworthy).
function Test-Encoder {
    param([string]$Encoder)
    $Family = Get-CodecFamily $Encoder
    $RcArgs = if ($Family -eq 'software') { @('-b:v','1M') }
              else { Build-HwVideoArgs -Family $Family -Mode 'bitrate' -Bitrate 1000 -MaxRate 1000 }
    $ProbeArgs = @('-hide_banner','-loglevel','error','-f','lavfi',
                   '-i','testsrc=s=256x144:d=0.1','-frames:v','1','-c:v',$Encoder) +
                 $RcArgs + @('-f','null','-')
    & $Script:FFmpeg @ProbeArgs 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Codec availability: word-anchored match over a *cached* `ffmpeg -encoders` (cheap, so the
# software path keeps its zero-probe overhead -- "compiled in" is enough for software).
function Test-EncoderAvailable {
    param([string]$Encoder)
    if (-not $Script:EncodersCache) {
        $Script:EncodersCache = (& $Script:FFmpeg -encoders 2>$null | Out-String)
    }
    return ($Script:EncodersCache -match "\b$([regex]::Escape($Encoder))\b")
}

# Walk $Script:SoftwareOrder and return the first compiled-in entry; libx264 if none match.
# Software default's single chokepoint (formerly Get-SoftwareCodec, hardcoded libx265->libx264).
function Get-SoftwareEncoder {
    foreach ($enc in $Script:SoftwareOrder) {
        if (Test-EncoderAvailable $enc) { return $enc }
    }
    return 'libx264'
}

# --- Persisted preferences (shrinkwrap.conf) ----------------------------------
# Format: `key = value`, `#` comments, space-separated lists. Read precedence:
# script-dir -> per-user -> built-in defaults. Write: script-dir, else per-user.
function Get-ConfigUserDir {
    if ($env:APPDATA)         { return (Join-Path $env:APPDATA 'ffmpeg-shrinkwrap') }
    if ($env:XDG_CONFIG_HOME) { return (Join-Path $env:XDG_CONFIG_HOME 'ffmpeg-shrinkwrap') }
    return (Join-Path $HOME '.config/ffmpeg-shrinkwrap')
}

function Get-ConfigReadPath {
    $sd = Join-Path $PSScriptRoot $Script:CONFIG_NAME
    if (Test-Path -LiteralPath $sd) { return $sd }
    $ud = Join-Path (Get-ConfigUserDir) $Script:CONFIG_NAME
    if (Test-Path -LiteralPath $ud) { return $ud }
    return $null
}

function Read-Config {
    # Populate raw $Script:Cfg* (+ ConfigFound) and effective Mode/HardwareOrder/SoftwareOrder.
    $Script:CfgMode = $null; $Script:CfgHwOrder = $null; $Script:CfgSwOrder = $null
    $Script:CfgTargetSizeMB = $null; $Script:CfgPreset = $null
    $Script:CfgNormalizeAudio = $null; $Script:CfgMono = $null; $Script:CfgNoAudio = $null
    $Script:CfgAudioBitrate = $null; $Script:CfgMinAudioBitrate = $null
    $Script:CfgMinVideoBitrate = $null; $Script:CfgMaxRetries = $null
    $Script:CfgCrfRescueValue = $null; $Script:CfgOutputDir = $null; $Script:CfgNoCleanup = $null
    $Script:ConfigFound = $false
    $path = Get-ConfigReadPath
    if ($path) {
        $Script:ConfigFound = $true
        foreach ($raw in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
            $line = $raw.Trim()                           # .Trim() also drops a trailing CR
            if ($line -eq '' -or $line.StartsWith('#')) { continue }
            $eq = $line.IndexOf('=')
            if ($eq -lt 0) { continue }                   # no '=' on the line -> skip
            $key   = $line.Substring(0, $eq).Trim()
            $value = $line.Substring($eq + 1).Trim()
            switch ($key) {
                'mode'              { $Script:CfgMode              = $value }
                'hardware_order'    { $Script:CfgHwOrder           = $value }
                'software_order'    { $Script:CfgSwOrder           = $value }
                'target_size_mb'    { $Script:CfgTargetSizeMB      = $value }
                'preset'            { $Script:CfgPreset            = $value }
                'normalize_audio'   { $Script:CfgNormalizeAudio    = $value }
                'mono'              { $Script:CfgMono              = $value }
                'no_audio'          { $Script:CfgNoAudio           = $value }
                'audio_bitrate'     { $Script:CfgAudioBitrate      = $value }
                'min_audio_bitrate' { $Script:CfgMinAudioBitrate   = $value }
                'min_video_bitrate' { $Script:CfgMinVideoBitrate   = $value }
                'max_retries'       { $Script:CfgMaxRetries        = $value }
                'crf_rescue_value'  { $Script:CfgCrfRescueValue    = $value }
                'output_dir'        { $Script:CfgOutputDir         = $value }
                'no_cleanup'        { $Script:CfgNoCleanup         = $value }
            }
        }
    }
    # Effective values: config overrides built-in defaults; missing keys fall back.
    $Script:Mode = if ($Script:CfgMode) { $Script:CfgMode } else { $Script:DEFAULT_MODE }
    $Script:HardwareOrder = if ($Script:CfgHwOrder) { @($Script:CfgHwOrder -split '\s+' | Where-Object { $_ }) } else { $Script:HwHierarchy }
    $Script:SoftwareOrder = if ($Script:CfgSwOrder) { @($Script:CfgSwOrder -split '\s+' | Where-Object { $_ }) } else { $Script:DEFAULT_SOFTWARE_ORDER }
}

function Write-Config {
    # <NewMode> : write conf preserving existing settings; return the path written, or $null.
    param([string]$NewMode)
    $hwOrder = if ($Script:CfgHwOrder) { $Script:CfgHwOrder } else { ($Script:HwHierarchy -join ' ') }
    $swOrder = if ($Script:CfgSwOrder) { $Script:CfgSwOrder } else { ($Script:DEFAULT_SOFTWARE_ORDER -join ' ') }
    $targetSize = if ($Script:CfgTargetSizeMB) { $Script:CfgTargetSizeMB } else { "19.8" }
    $preset = if ($Script:CfgPreset) { $Script:CfgPreset } else { "slow" }
    $normAudio = if ($Script:CfgNormalizeAudio) { $Script:CfgNormalizeAudio } else { "false" }
    $mono = if ($Script:CfgMono) { $Script:CfgMono } else { "false" }
    $noAudio = if ($Script:CfgNoAudio) { $Script:CfgNoAudio } else { "false" }
    $audBitrate = if ($Script:CfgAudioBitrate) { $Script:CfgAudioBitrate } else { "192" }
    $minAudBitrate = if ($Script:CfgMinAudioBitrate) { $Script:CfgMinAudioBitrate } else { "64" }
    $minVidBitrate = if ($Script:CfgMinVideoBitrate) { $Script:CfgMinVideoBitrate } else { "500" }
    $retries = if ($Script:CfgMaxRetries) { $Script:CfgMaxRetries } else { "3" }
    $crfRescue = if ($Script:CfgCrfRescueValue) { $Script:CfgCrfRescueValue } else { "28" }
    $outDir = if ($Script:CfgOutputDir) { $Script:CfgOutputDir } else { "optimized" }
    $noClean = if ($Script:CfgNoCleanup) { $Script:CfgNoCleanup } else { "false" }

    $content = @"
# ffmpeg-shrinkwrap preferences.
# Regenerate:  shrinkwrap --config   |   .\shrinkwrap.ps1 -Config     (or edit by hand)
# Delete this file to return to defaults (software x265, 19.8MB target).
#
# mode: drives encoder choice when no -c/-Encoder flag is given.
#   hardware       - walk hardware_order (GPU); fall back to software_order
#   software       - walk software_order (x265 first)
#   software_x264  - force libx264 (maximum compatibility / legacy)
mode = $NewMode

# Ordered candidates. Each entry is probed; the first that works wins. Reorder/trim freely.
hardware_order = $hwOrder
software_order = $swOrder

# --- Compression & Speed Defaults ---
# target_size_mb: target file size in MB (default: 19.8 for Discord 20MB limit)
# preset: x265/universal preset (slow, medium, fast, faster, etc. default: slow)
target_size_mb = $targetSize
preset = $preset

# --- Audio Defaults ---
# normalize_audio: apply EBU R128 loudness normalization (true/false, default: false)
# mono: downmix audio to mono to save budget (true/false, default: false)
# no_audio: strip audio completely (true/false, default: false)
# audio_bitrate: initial audio bitrate in kbps (default: 192)
# min_audio_bitrate: audio bitrate floor in kbps (default: 64)
normalize_audio = $normAudio
mono = $mono
no_audio = $noAudio
audio_bitrate = $audBitrate
min_audio_bitrate = $minAudBitrate

# --- Output & Fallback Options ---
# output_dir: destination directory for compressed videos (default: optimized)
# min_video_bitrate: video bitrate floor in kbps before 720p rescue (default: 500)
# max_retries: max retry attempts per resolution pass (default: 3)
# crf_rescue_value: CRF quality value for Phase 3 rescue pass (default: 28)
# no_cleanup: preserve logs and intermediate pass files (true/false, default: false)
output_dir = $outDir
min_video_bitrate = $minVidBitrate
max_retries = $retries
crf_rescue_value = $crfRescue
no_cleanup = $noClean
"@
    # UTF-8 without BOM so the Bash port reads it cleanly (the conf is shared cross-port).
    $Utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $sd = Join-Path $PSScriptRoot $Script:CONFIG_NAME
    try {
        [System.IO.File]::WriteAllText($sd, $content, $Utf8NoBom)
        return $sd
    } catch {}
    $udDir = Get-ConfigUserDir
    $ud = Join-Path $udDir $Script:CONFIG_NAME
    try {
        if (-not (Test-Path -LiteralPath $udDir)) {
            New-Item -ItemType Directory -Path $udDir -Force -ErrorAction Stop | Out-Null
        }
        [System.IO.File]::WriteAllText($ud, $content, $Utf8NoBom)
        return $ud
    } catch {}
    return $null
}

function Invoke-ConfigWizard {
    # Interactive setup: prompt for a default encoder, write the conf, and exit (no processing).
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        [Console]::Error.WriteLine("-Config needs an interactive terminal")
        exit 1
    }
    Write-Host "First-time setup - choose your default encoder:"
    Write-Host "  [1] Hardware (GPU)    Fast, offloads to GPU. Usually a bit larger / lower-quality at the"
    Write-Host "                        size cap; hardware AV1/HEVC may not play inline on Discord for"
    Write-Host "                        everyone. Falls back to software if no GPU encoder works."
    Write-Host "  [2] Software x265     (Recommended) Best quality at the cap (libx265 2-pass); plays"
    Write-Host "                        inline on Discord. Slower. Falls back to x264."
    Write-Host "  [3] Software x264     Maximum compatibility / legacy. Plays everywhere, larger files."
    $answer = Read-Host "Your choice [2]"
    switch ($answer) {
        '1'     { $NewMode = 'hardware' }
        '3'     { $NewMode = 'software_x264' }
        default { $NewMode = 'software' }              # empty Enter / anything else -> default
    }
    $saved = Write-Config -NewMode $NewMode
    if ($saved) {
        Write-Host "Saved to $saved."
        exit 0
    }
    [Console]::Error.WriteLine("ERROR: could not write config (script dir and per-user dir both unwritable).")
    exit 1
}

# Resolve the encoder: -Encoder flag (per-run) > config mode > built-in default (software x265).
# Sets $Script:VideoCodec + $Script:CodecFamily + $Script:CodecSource.
function Resolve-Encoder {
    if ($Script:EncoderExplicit) {
        $choice = $Encoder
        $Script:CodecSource = '-Encoder flag'
    } elseif ($Script:ConfigFound) {
        switch ($Script:Mode) {
            'hardware'      { $choice = 'hw' }
            'software'      { $choice = 'auto' }
            'software_x264' { $choice = 'software_x264' }
            default         { $choice = 'auto' }       # unknown mode -> safe software default
        }
        $Script:CodecSource = "config: $($Script:Mode)"
    } else {
        $choice = 'auto'
        $Script:CodecSource = 'default'
    }

    switch ($choice) {
        'auto' {
            $Script:VideoCodec = Get-SoftwareEncoder   # software list via cheap grep
        }
        'software_x264' {
            if (Test-EncoderAvailable 'libx264') { $Script:VideoCodec = 'libx264' }
            else { $Script:VideoCodec = Get-SoftwareEncoder }
        }
        'hw' {
            Write-ColorOutput "  [Encoder] Probing hardware encoders..." "Cyan"
            $Found = $null
            foreach ($enc in $Script:HardwareOrder) {
                if (Test-Encoder $enc) { $Found = $enc; break }
            }
            if ($Found) {
                $Script:VideoCodec = $Found
                Write-ColorOutput "  [Encoder] Hardware encoder: $Found" "Green"
            } else {
                $Script:VideoCodec = Get-SoftwareEncoder
                Write-ColorOutput "  [Encoder] No working hardware encoder found; using software ($Script:VideoCodec)." "Yellow"
            }
        }
        default {
            if (Test-Encoder $choice) {
                $Script:VideoCodec = $choice
                Write-ColorOutput "  [Encoder] Using $choice" "Green"
            } else {
                $Script:VideoCodec = Get-SoftwareEncoder
                Write-ColorOutput "  [Encoder] '$choice' failed validation; falling back to software ($Script:VideoCodec)." "Yellow"
            }
        }
    }
    $Script:CodecFamily = Get-CodecFamily $Script:VideoCodec
}

# Single-pass hardware encode. Plugs into the same call sites as the software 2-pass path:
# Invoke-FFmpegEncode returns 0 for Pass 1 (no stats file needed) and routes Pass 2 here.
function Invoke-HwEncode {
    param([string]$InputFile, [string]$OutputFile, [hashtable]$VideoParams, [hashtable]$AudioParams)

    # A CRF request maps to the constant-quality rescue; otherwise capped VBR at the bitrate.
    if ($VideoParams.CRF) {
        $Mode = 'cq';      $MaxRate = [int]$VideoParams.MaxRate; $Bitrate = $MaxRate
    } else {
        $Mode = 'bitrate'; $Bitrate = [int]$VideoParams.Bitrate; $MaxRate = $Bitrate
    }

    $FFArgs = @("-y", "-i", $InputFile)
    $FFArgs += $Script:VsyncFlag.Split(' ')
    $FFArgs += "-c:v", $Script:VideoCodec
    $FFArgs += "-pix_fmt", "yuv420p"
    $FFArgs += (Build-HwVideoArgs -Family $Script:CodecFamily -Mode $Mode -Bitrate $Bitrate -MaxRate $MaxRate)
    if ($VideoParams.Scale) { $FFArgs += "-vf", $VideoParams.Scale }
    if ($NoAudio) {
        $FFArgs += "-an"
    } else {
        $FFArgs += "-c:a", "aac"
        $FFArgs += "-b:a", "$($AudioParams.Bitrate)k"
        if ($AudioParams.NormFilter) { $FFArgs += "-af", $AudioParams.NormFilter }
        $FFArgs += "-ac", "$($Script:AudioChannels)"
    }
    $FFArgs += "-map_metadata", "0"
    $FFArgs += "-movflags", "+faststart"
    $FFArgs += $OutputFile

    & $Script:FFmpeg @FFArgs 2> "$OutputFile.log" | Out-Null
    return $LASTEXITCODE
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

    # Hardware families are single-pass: Pass 1 (stats analysis) is a no-op, and the real
    # encode happens on the Pass 2 call. This keeps every existing "if (pass1) { pass2 }"
    # call site working unmodified. The software path below is unchanged.
    if ($Script:CodecFamily -ne 'software') {
        if ($Pass -eq 1) { return 0 }
        return Invoke-HwEncode -InputFile $InputFile -OutputFile $OutputFile `
            -VideoParams $VideoParams -AudioParams $AudioParams
    }
    
    # Build a clean argument ARRAY and invoke via the call operator (& exe @args). Each
    # element becomes a single argv entry, so no manual quoting is needed and paths with
    # spaces / & / ( ) are handled correctly.
    $FFArgs = @("-y", "-i", $InputFile)
    $FFArgs += $Script:VsyncFlag.Split(' ')

    if ($Pass -gt 0) {
        $FFArgs += "-pass", $Pass, "-passlogfile", $PassLogFile
    }

    # Video params
    $FFArgs += "-c:v", $Script:VideoCodec
    $FFArgs += "-pix_fmt", "yuv420p"

    if ($VideoParams.Bitrate) { $FFArgs += "-b:v", "$($VideoParams.Bitrate)k" }
    if ($VideoParams.CRF)     { $FFArgs += "-crf", $VideoParams.CRF }
    if ($VideoParams.MaxRate) { $FFArgs += "-maxrate", "$($VideoParams.MaxRate)k" }
    if ($VideoParams.BufSize) { $FFArgs += "-bufsize", "$($VideoParams.BufSize)k" }
    if ($VideoParams.Preset)  { $FFArgs += "-preset", $VideoParams.Preset }
    if ($VideoParams.Scale)   { $FFArgs += "-vf", $VideoParams.Scale }

    # Audio params
    if ($Pass -eq 1 -or $NoAudio) {
        $FFArgs += "-an" # No audio in pass 1 (and whenever -NoAudio strips it)
    } else {
        $FFArgs += "-c:a", "aac"
        $FFArgs += "-b:a", "$($AudioParams.Bitrate)k"
        if ($AudioParams.NormFilter) {
            $FFArgs += "-af", $AudioParams.NormFilter
        }
        $FFArgs += "-ac", "$($Script:AudioChannels)"
    }

    if ($Pass -eq 1) {
        $FFArgs += "-f", "null", "NUL"
    } else {
        $FFArgs += "-map_metadata", "0"
        $FFArgs += "-movflags", "+faststart"
        $FFArgs += $OutputFile
    }

    # Handle log path (stderr capture)
    $LogPath = "$OutputFile.log"
    if ($OutputFile -eq "NUL") {
        $LogPath = Join-Path $Script:OUTPUT_DIR "ffmpeg_pass1_$PID.log"
    }

    # Execute: stderr -> log file, discard stdout, exit code from $LASTEXITCODE.
    & $Script:FFmpeg @FFArgs 2> $LogPath | Out-Null
    return $LASTEXITCODE
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
    
    $EstAudioBytes = Get-AudioBudgetBytes $MinAudioBitrate $Duration
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
    
    # Phase 3: Last Resort capped CRF rescue @ 720p
    $CrfMaxRate = [math]::Floor((($TargetSizeBytes - (Get-AudioBudgetBytes 64 $Duration) - $OverheadBytes) * 8 / $Duration) / 1000)
    if ($CrfMaxRate -lt $MinVideoBitrate) { $CrfMaxRate = $MinVideoBitrate }
    $CrfBufSize = $CrfMaxRate * 2
    Write-ColorOutput "  [Rescue] Phase 3: Last resort capped CRF $($Script:CRF_RESCUE_VALUE) @ 720p (maxrate ${CrfMaxRate}k)..." "Yellow"

    Show-Progress "CRF Pass" "Encoding" 0
    $ExitCodeCRF = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile $TempFile `
        -VideoParams @{ CRF=$Script:CRF_RESCUE_VALUE; MaxRate=$CrfMaxRate; BufSize=$CrfBufSize; Preset=$Preset; Scale="scale='min(1280,iw)':-2" } `
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
    $AbsoluteMinAudioBytes = Get-AudioBudgetBytes $MinAudioBitrate $Duration
    $AbsoluteMinTotalMB = ($AbsoluteMinVideoBytes + $AbsoluteMinAudioBytes) / 1MB
    
    # If rescue might work, try that first; fall through to splitting if it fails.
    if ($AbsoluteMinTotalMB -le $TargetSizeMB) {
        Write-ColorOutput "  Video might fit with rescue mode. Attempting rescue before split..." "Yellow"
        if (Invoke-RescueMode $InputFile $PartSuffix) {
            return $true
        }
        Write-ColorOutput "  Rescue failed. Falling back to keyframe split..." "Yellow"
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
    
    # Split via the call operator (handles spaces/special chars in paths). Format the
    # split point invariantly so a comma-decimal locale doesn't feed ffmpeg "6,5".
    $SplitPointStr = ([double]$SplitPoint).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $Args1 = @("-y", "-i", $InputFile, "-t", $SplitPointStr, "-c", "copy", "-avoid_negative_ts", "1", $Part1File)
    $Args2 = @("-y", "-i", $InputFile, "-ss", $SplitPointStr, "-c", "copy", "-avoid_negative_ts", "1", $Part2File)

    & $Script:FFmpeg @Args1 2> "$Part1File.log" | Out-Null
    $Exit1 = $LASTEXITCODE
    & $Script:FFmpeg @Args2 2> "$Part2File.log" | Out-Null
    $Exit2 = $LASTEXITCODE

    if ($Exit1 -ne 0 -or $Exit2 -ne 0) {
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
        if ($NoAudio) {
            # Honor -NoAudio even on the no-encode fast path: stream-copy video, drop audio
            # (lossless); fall back to a plain copy if the container can't remux.
            & $Script:FFmpeg -y -i $InputFile -c copy -an -movflags +faststart $OutputFile 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Copy-Item $InputFile $OutputFile -Force }
            Record-Summary "$FileName$PartSuffix" $OrigSizeMB (Get-FileSizeMB $OutputFile) "Copied"
        } else {
            Copy-Item $InputFile $OutputFile -Force
            Record-Summary "$FileName$PartSuffix" $OrigSizeMB $OrigSizeMB "Copied"
        }
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
    
    $EstAudioBytes = Get-AudioBudgetBytes $AudioBitrateKbps $Duration
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
    $UpwardCorrectionDone = $false # Reclaim-headroom guard (bidirectional convergence runs once)
    
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

            # Bidirectional convergence: if we landed well under target, reclaim the
            # unused headroom once by re-encoding upward (ABR otherwise only lowers).
            if (-not $UpwardCorrectionDone -and $FinalSizeMB -gt 0 -and $FinalSizeMB -lt ($TargetSizeMB * 0.9)) {
                $UpwardCorrectionDone = $true
                $PrevGoodSize = $FinalSizeMB
                $UpwardKbps = [math]::Floor($CurrentVideoKbps * $TargetSizeMB / $FinalSizeMB)
                if ($UpwardKbps -gt $Script:MAX_VIDEO_BITRATE_KBPS) { $UpwardKbps = $Script:MAX_VIDEO_BITRATE_KBPS }
                Write-ColorOutput "  Result well under target (${FinalSizeMB}MB). Reclaiming headroom @ ~${UpwardKbps}kbps..." "Gray"

                Show-Progress "Pass 1" "Analyzing" 0
                $UpExit1 = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile "NUL" `
                    -VideoParams @{ Bitrate=$UpwardKbps; Preset=$Preset; Scale="scale='min(1920,iw)':-2" } `
                    -AudioParams @{} -PassLogFile $PassLog -Pass 1
                Show-Progress "Pass 1" "Analyzing" 100
                Write-Host ""

                $UpExit2 = 1
                if ($UpExit1 -eq 0) {
                    Show-Progress "Pass 2" "Encoding" 0
                    $UpExit2 = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile $TempFile `
                        -VideoParams @{ Bitrate=$UpwardKbps; Preset=$Preset; Scale="scale='min(1920,iw)':-2" } `
                        -AudioParams @{ Bitrate=$AudioBitrateKbps; NormFilter=$AudioFilter } -PassLogFile $PassLog -Pass 2
                    Show-Progress "Pass 2" "Encoding" 100
                    Write-Host ""
                }

                if ($UpExit2 -eq 0) {
                    $UpwardSize = Get-FileSizeMB $TempFile
                    # Keep the upward result only if it stayed within the hard cap and is
                    # genuinely closer to target (larger) than the result we already have.
                    if ($UpwardSize -le $Script:MAX_SIZE_MB -and $UpwardSize -gt $PrevGoodSize) {
                        Move-Item $TempFile $OutputFile -Force
                        $FinalSizeMB = $UpwardSize
                        Write-ColorOutput "  Headroom reclaimed: ${FinalSizeMB}MB" "Gray"
                    } else {
                        Write-ColorOutput "  Upward retry (${UpwardSize}MB) not usable; keeping ${PrevGoodSize}MB result." "Gray"
                        Remove-Item $TempFile -ErrorAction SilentlyContinue
                    }
                } else {
                    Write-ColorOutput "  Upward retry failed; keeping ${PrevGoodSize}MB result." "Gray"
                    Remove-Item $TempFile -ErrorAction SilentlyContinue
                }
            }

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
                if (-not $NoAudio -and $AudioBitrateKbps -gt $MinAudioBitrate) {
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
    
    # CRF Rescue (capped): CRF rescue quality with a VBV cap so it cannot overshoot the
    # target, and isn't artificially size-limited when the content is easy.
    $CrfMaxRate = [math]::Floor((($TargetSizeBytes - (Get-AudioBudgetBytes 64 $Duration) - $OverheadBytes) * 8 / $Duration) / 1000)
    if ($CrfMaxRate -lt $MinVideoBitrate) { $CrfMaxRate = $MinVideoBitrate }
    $CrfBufSize = $CrfMaxRate * 2
    Write-ColorOutput "  [Info] Attempting capped CRF $($Script:CRF_RESCUE_VALUE) rescue (maxrate ${CrfMaxRate}k) before splitting..." "Yellow"

    Show-Progress "CRF Pass" "Encoding" 0
    $ExitCodeCRF = Invoke-FFmpegEncode -InputFile $InputFile -OutputFile $TempFile `
        -VideoParams @{ CRF=$Script:CRF_RESCUE_VALUE; MaxRate=$CrfMaxRate; BufSize=$CrfBufSize; Preset=$Preset; Scale="scale='min(1920,iw)':-2" } `
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

# Load persisted preferences (script-dir -> per-user -> built-in defaults).
Read-Config

# -Config is pure setup: run the wizard, write the conf, and exit before any processing.
if ($Config) {
    Invoke-ConfigWizard
}

# Apply persisted preferences if CLI arguments were not explicitly supplied
if (-not $PSBoundParameters.ContainsKey('TargetSizeMB') -and $Script:CfgTargetSizeMB) {
    $parsed = 0.0
    if ([double]::TryParse($Script:CfgTargetSizeMB, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 0) {
        $TargetSizeMB = $parsed
    }
}
if (-not $PSBoundParameters.ContainsKey('Preset') -and $Script:CfgPreset) {
    $Preset = $Script:CfgPreset
}
if (-not $PSBoundParameters.ContainsKey('NormalizeAudio') -and $Script:CfgNormalizeAudio -eq 'true') {
    $NormalizeAudio = [switch]::new($true)
}
if (-not $PSBoundParameters.ContainsKey('Mono') -and $Script:CfgMono -eq 'true') {
    $Mono = [switch]::new($true)
    $Script:AudioChannels = 1
}
if (-not $PSBoundParameters.ContainsKey('NoAudio') -and $Script:CfgNoAudio -eq 'true') {
    $NoAudio = [switch]::new($true)
}
if (-not $PSBoundParameters.ContainsKey('MinVideoBitrate') -and $Script:CfgMinVideoBitrate) {
    $parsed = 0
    if ([int]::TryParse($Script:CfgMinVideoBitrate, [ref]$parsed) -and $parsed -gt 0) { $MinVideoBitrate = $parsed }
}
if (-not $PSBoundParameters.ContainsKey('MinAudioBitrate') -and $Script:CfgMinAudioBitrate) {
    $parsed = 0
    if ([int]::TryParse($Script:CfgMinAudioBitrate, [ref]$parsed) -and $parsed -gt 0) { $MinAudioBitrate = $parsed }
}
if (-not $PSBoundParameters.ContainsKey('MaxRetries') -and $Script:CfgMaxRetries) {
    $parsed = 0
    if ([int]::TryParse($Script:CfgMaxRetries, [ref]$parsed) -and $parsed -gt 0) { $MaxRetries = $parsed }
}
if (-not $PSBoundParameters.ContainsKey('NoCleanup') -and $Script:CfgNoCleanup -eq 'true') {
    $NoCleanup = [switch]::new($true)
}
if ($OutputDir) {
    $Script:OUTPUT_DIR = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $PSScriptRoot $OutputDir }
} elseif ($Script:CfgOutputDir) {
    $Script:OUTPUT_DIR = if ([System.IO.Path]::IsPathRooted($Script:CfgOutputDir)) { $Script:CfgOutputDir } else { Join-Path $PSScriptRoot $Script:CfgOutputDir }
}
if ($Script:CfgAudioBitrate) {
    $parsed = 0
    if ([int]::TryParse($Script:CfgAudioBitrate, [ref]$parsed) -and $parsed -gt 0) { $Script:INITIAL_AUDIO_BITRATE_KBPS = $parsed }
}
if ($Script:CfgCrfRescueValue) {
    $parsed = 0
    if ([int]::TryParse($Script:CfgCrfRescueValue, [ref]$parsed) -and $parsed -gt 0) { $Script:CRF_RESCUE_VALUE = $parsed }
}

$Script:MAX_SIZE_MB = [math]::Ceiling($TargetSizeMB)

# Setup
if (-not (Test-Path $Script:OUTPUT_DIR)) {
    New-Item -ItemType Directory -Path $Script:OUTPUT_DIR | Out-Null
}

$Script:FFmpeg = Get-FFmpegPath
$Script:FFprobe = Get-FFprobePath

if (-not $Script:FFprobe) {
    Write-ColorOutput "WARNING: ffprobe not found. Some features may be limited." "Yellow"
}

# Resolve encoder: -Encoder flag > config mode > built-in software default; probe + route.
Resolve-Encoder

# Normalize the preset to a token valid for the encoder we landed on (warn once on a
# cross-vendor mismatch), so any preset string runs as intended on any encoder.
$PresetResolved = Resolve-PresetToken -Family $Script:CodecFamily -Preset $Preset
Warn-PresetMismatch -Family $Script:CodecFamily -Raw $Preset -Resolved $PresetResolved
$Preset = $PresetResolved

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

$AudioMode = if ($NoAudio) { "none" } elseif ($NormalizeAudio) { "normalized" } else { "default" }
if ($Mono -and -not $NoAudio) { $AudioMode += ", mono" }
Write-Banner $TargetSizeMB "$($Script:VideoCodec) ($($Script:CodecSource))" $Preset $AudioMode

# Gather files
if ($Files.Count -eq 0) {
    Write-ColorOutput "No files specified. Scanning current directory for video files..." "Cyan"
    $Files = Get-ChildItem -Path $PSScriptRoot -File |
        Where-Object { $Script:InputExtensions -contains $_.Extension.ToLower() } |
        Select-Object -ExpandProperty FullName
}

# Filter out already-optimized files and expand folders
$FilesToProcess = @()
foreach ($File in $Files) {
    if (Test-Path $File -PathType Container) {
        Write-ColorOutput "Folder detected: $File - Scanning for videos..." "Cyan"
        $FolderFiles = Get-ChildItem -Path $File -File -Recurse |
            Where-Object { $Script:InputExtensions -contains $_.Extension.ToLower() } |
            Select-Object -ExpandProperty FullName
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
    Write-ColorOutput "No supported video files found to process." "Red"
    Wait-ForExit
    exit 0
}

Write-ColorOutput "Found $($FilesToProcess.Count) file(s) to process." "Green"

$Total = $FilesToProcess.Count
$Idx = 0
$TotalInMB = 0.0

try {
    # Process all files
    foreach ($File in $FilesToProcess) {
        $Idx++
        if (-not (Test-Path $File)) {
            Write-ColorOutput "File not found: $File" "Red"
            continue
        }

        Write-FileHeader $Idx $Total ([System.IO.Path]::GetFileName($File))
        $TotalInMB += [double](Get-FileSizeMB $File)
        $null = Optimize-Video $File
    }

    # Generate Summary Report (text + CSV)
    Write-ColorOutput "`nWriting summary to $Script:SUMMARY_FILE..." "Cyan"

    $SummaryContent = @()
    $SummaryContent += "{0,-40} {1,-12} {2,-12} {3,-12} {4,-15}" -f "File", "Orig Size", "Final Size", "Reduction %", "Status"
    $SummaryContent += "-" * 91

    foreach ($Row in $Script:Report) {
        $Name = "$($Row.File)"
        $NameTrunc = $Name.Substring(0, [math]::Min(40, $Name.Length))
        $SummaryContent += "{0,-40} {1,-12} {2,-12} {3,-12} {4,-15}" -f `
            $NameTrunc, $Row.OrigSizeMB, $Row.FinalSizeMB, $Row.ReductionPct, $Row.Status
    }

    $SummaryContent | Out-File $Script:SUMMARY_FILE -Encoding UTF8

    # Structured CSV alongside the text report (free via Export-Csv).
    $CsvFile = [System.IO.Path]::ChangeExtension($Script:SUMMARY_FILE, ".csv")
    $Script:Report | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8

    # Batch tally (console only; the summary files above are intentionally unchanged).
    $TotalOutMB = 0.0
    foreach ($Row in $Script:Report) {
        $fin = $Row.FinalSizeMB -as [double]
        if ($fin -and $fin -gt 0) { $TotalOutMB += $fin }
    }
    $Elapsed = $Script:Stopwatch.Elapsed
    $ElapsedStr = "{0}m {1:00}s" -f [int][math]::Floor($Elapsed.TotalMinutes), $Elapsed.Seconds
    Write-Tally $TotalInMB $TotalOutMB $ElapsedStr
}
finally {
    # Runs on normal completion AND on Ctrl+C, so an interrupted run cleans up after itself.
    if (-not $NoCleanup) {
        Write-ColorOutput "Cleaning up temporary artifacts..." "Gray"
    }
    Invoke-Cleanup
}

Write-ColorOutput "`nOptimization complete! Summary in $Script:SUMMARY_FILE" "Green"
Write-ColorOutput "Optimized files are in: $Script:OUTPUT_DIR" "Cyan"

Wait-ForExit "`nPress Enter to exit"