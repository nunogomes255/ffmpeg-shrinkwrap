<#
.SYNOPSIS
    Automatically downloads and extracts FFmpeg for Shrinkwrap
#>

$ErrorActionPreference = "Stop"

# --- Pinned FFmpeg release (supply-chain integrity) ---
# We pin a specific, immutable build and verify its SHA-256 before extracting, instead of
# blindly trusting whatever "latest" returns. The hash below is gyan.dev's published
# checksum for this exact essentials build.
# TO BUMP THE VERSION: change $FFmpegVersion AND replace $ExpectedSha256 with the new
# value from https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-<ver>-essentials_build.zip.sha256
$FFmpegVersion  = "8.1.1"
$ExpectedSha256 = "6F58CE889F59C311410F7D2B18895B33C03456463486F3B1EBC93D97A0F54541"
# Primary: gyan.dev versioned package. Fallback: GitHub release asset (same immutable build).
$FFmpegURL       = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-$FFmpegVersion-essentials_build.zip"
$FFmpegGitHubURL = "https://github.com/GyanD/codexffmpeg/releases/download/$FFmpegVersion/ffmpeg-$FFmpegVersion-essentials_build.zip"
$DownloadPath = Join-Path $PSScriptRoot "ffmpeg-essentials.zip"
$ExtractPath = Join-Path $PSScriptRoot "ffmpeg-temp"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  FFmpeg Shrinkwrap - Setup Wizard" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "About this download:" -ForegroundColor Gray
Write-Host "  - FFmpeg is open-source video processing software" -ForegroundColor Gray
Write-Host "  - Official site: https://ffmpeg.org/" -ForegroundColor Gray
Write-Host "  - Build provider: Gyan Doshi (listed on ffmpeg.org)" -ForegroundColor Gray
Write-Host "  - Source code: https://github.com/GyanD/codexffmpeg" -ForegroundColor Gray
Write-Host ""

# Check if already installed
if ((Test-Path (Join-Path $PSScriptRoot "ffmpeg.exe")) -and 
    (Test-Path (Join-Path $PSScriptRoot "ffprobe.exe"))) {
    Write-Host "[OK] FFmpeg is already installed!" -ForegroundColor Green
    Write-Host ""
    Write-Host "You can now use drag_videos_here.bat or run:" -ForegroundColor White
    Write-Host "  .\shrinkwrap.ps1" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 0
}

Write-Host "FFmpeg not found. Starting automatic download..." -ForegroundColor Yellow
Write-Host ""

# Download FFmpeg
try {
    Write-Host "[1/4] Downloading FFmpeg $FFmpegVersion (~100MB)..." -ForegroundColor Cyan
    Write-Host "      Primary: gyan.dev (official FFmpeg build provider)" -ForegroundColor Gray
    
    # Try primary source first
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $FFmpegURL -Destination $DownloadPath -Description "Downloading FFmpeg"
        } else {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $FFmpegURL -OutFile $DownloadPath -UseBasicParsing
            $ProgressPreference = 'Continue'
        }
    } catch {
        Write-Host "      Primary source failed. Trying GitHub mirror..." -ForegroundColor Yellow
        
        # Fallback to GitHub
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $FFmpegGitHubURL -Destination $DownloadPath -Description "Downloading FFmpeg from GitHub"
        } else {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $FFmpegGitHubURL -OutFile $DownloadPath -UseBasicParsing
            $ProgressPreference = 'Continue'
        }
    }
    
    Write-Host "      Download complete!" -ForegroundColor Green
    
} catch {
    Write-Host "[ERROR] Download failed: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please download manually from either:" -ForegroundColor Yellow
    Write-Host "  1. https://www.gyan.dev/ffmpeg/builds/ (Official)" -ForegroundColor Cyan
    Write-Host "  2. https://github.com/GyanD/codexffmpeg/releases (GitHub Mirror)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Verify on FFmpeg.org: https://ffmpeg.org/download.html#build-windows" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Then extract ffmpeg.exe and ffprobe.exe to:" -ForegroundColor Yellow
    Write-Host "  $PSScriptRoot" -ForegroundColor Cyan
    Read-Host "Press Enter to exit"
    exit 1
}

# Verify integrity before trusting the archive (pinned SHA-256)
try {
    Write-Host "[1.5/4] Verifying SHA-256 checksum..." -ForegroundColor Cyan
    $ActualSha256 = (Get-FileHash -Path $DownloadPath -Algorithm SHA256).Hash
    if ($ActualSha256 -ne $ExpectedSha256) {
        Write-Host "[ERROR] Checksum mismatch! The download may be corrupted or tampered with." -ForegroundColor Red
        Write-Host "        Expected: $ExpectedSha256" -ForegroundColor Yellow
        Write-Host "        Actual:   $ActualSha256" -ForegroundColor Yellow
        Write-Host "        Aborting and deleting the file for safety." -ForegroundColor Yellow
        Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "      Checksum verified (FFmpeg $FFmpegVersion)." -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Could not compute checksum: $_" -ForegroundColor Red
    Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
    Read-Host "Press Enter to exit"
    exit 1
}

# Extract archive
try {
    Write-Host "[2/4] Extracting archive..." -ForegroundColor Cyan
    
    # Remove old extraction directory if it exists
    if (Test-Path $ExtractPath) {
        Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # Create fresh extraction directory
    New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null
    
    # Extract with error handling
    try {
        Expand-Archive -Path $DownloadPath -DestinationPath $ExtractPath -Force -ErrorAction Stop
        Write-Host "      Extraction complete!" -ForegroundColor Green
    } catch {
        # Try alternative extraction method using Shell.Application COM object
        Write-Host "      Trying alternative extraction method..." -ForegroundColor Yellow
        
        $Shell = New-Object -ComObject Shell.Application
        $Zip = $Shell.NameSpace($DownloadPath)
        $Destination = $Shell.NameSpace($ExtractPath)
        $Destination.CopyHere($Zip.Items(), 16)
        
        Write-Host "      Extraction complete!" -ForegroundColor Green
    }
    
} catch {
    Write-Host "[ERROR] Extraction failed: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "The downloaded file is at:" -ForegroundColor Yellow
    Write-Host "  $DownloadPath" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Please manually:" -ForegroundColor Yellow
    Write-Host "  1. Extract the ZIP file using Windows Explorer or 7-Zip" -ForegroundColor White
    Write-Host "  2. Find ffmpeg.exe and ffprobe.exe in the bin\ folder" -ForegroundColor White
    Write-Host "  3. Copy them to: $PSScriptRoot" -ForegroundColor Cyan
    Write-Host ""
    Remove-Item $DownloadPath -ErrorAction SilentlyContinue
    Read-Host "Press Enter to exit"
    exit 1
}

# Find and copy binaries
try {
    Write-Host "[3/4] Locating binaries..." -ForegroundColor Cyan
    
    # FFmpeg essentials zip has structure: ffmpeg-X.X.X-essentials_build/bin/ffmpeg.exe
    # Search recursively for the executables
    $FFmpegExe = Get-ChildItem -Path $ExtractPath -Filter "ffmpeg.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $FFprobeExe = Get-ChildItem -Path $ExtractPath -Filter "ffprobe.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if (-not $FFmpegExe) {
        Write-Host "[ERROR] Could not find ffmpeg.exe in extracted archive" -ForegroundColor Red
        Write-Host "      Archive structure may have changed." -ForegroundColor Yellow
        Write-Host "      Please check $ExtractPath and copy manually" -ForegroundColor Yellow
        throw "ffmpeg.exe not found"
    }
    
    if (-not $FFprobeExe) {
        Write-Host "[WARNING] Could not find ffprobe.exe (optional)" -ForegroundColor Yellow
    }
    
    # Copy files
    Write-Host "      Found ffmpeg.exe at: $($FFmpegExe.Directory.FullName)" -ForegroundColor Gray
    Copy-Item $FFmpegExe.FullName -Destination $PSScriptRoot -Force
    Write-Host "      Copied ffmpeg.exe" -ForegroundColor Green
    
    if ($FFprobeExe) {
        Copy-Item $FFprobeExe.FullName -Destination $PSScriptRoot -Force
        Write-Host "      Copied ffprobe.exe" -ForegroundColor Green
    }
    
    Write-Host "      Installation complete!" -ForegroundColor Green
    
} catch {
    Write-Host "[ERROR] Failed to copy binaries: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "The downloaded files are in:" -ForegroundColor Yellow
    Write-Host "  $ExtractPath" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Please manually:" -ForegroundColor Yellow
    Write-Host "  1. Open that folder" -ForegroundColor White
    Write-Host "  2. Find ffmpeg.exe and ffprobe.exe" -ForegroundColor White
    Write-Host "  3. Copy them to: $PSScriptRoot" -ForegroundColor Cyan
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# Cleanup
try {
    Write-Host "[4/4] Cleaning up temporary files..." -ForegroundColor Cyan
    
    Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Host "      Cleanup complete!" -ForegroundColor Green
    
} catch {
    Write-Host "[WARNING] Could not remove temporary files" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "You can now use:" -ForegroundColor White
Write-Host "  - Drag videos onto drag_videos_here.bat" -ForegroundColor Cyan
Write-Host "  - Double-click drag_videos_here.bat" -ForegroundColor Cyan
Write-Host "  - Run .\shrinkwrap.ps1 directly" -ForegroundColor Cyan
Write-Host ""

Read-Host "Press Enter to exit"