@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"

title FFmpeg Shrinkwrap - Discord Video Compressor

:: ============================================
::   ONE-CLICK VIDEO COMPRESSOR FOR DISCORD
:: ============================================
echo.
echo ========================================
echo   FFmpeg Shrinkwrap v1.0
echo   Compress videos for Discord (10MB)
echo ========================================
echo.

:: ====================
:: STEP 1: Check FFmpeg
:: ====================

if exist "ffmpeg.exe" goto :ffmpeg_found

:: FFmpeg not found - offer auto-install
echo [1/2] FFmpeg not detected - first-time setup required
echo.
echo This tool needs FFmpeg (free video processing software).
echo.
echo What is FFmpeg?
echo   - Open-source video encoder (used by YouTube, VLC, etc)
echo   - Official site: https://ffmpeg.org
echo   - Download from: gyan.dev (official Windows build provider)
echo   - Size: ~100MB (one-time download)
echo.
echo You can verify this is legitimate at:
echo   https://ffmpeg.org/download.html#build-windows
echo.

choice /C YN /M "Auto-download FFmpeg now? (Required to continue)"
if errorlevel 2 goto :manual_install

:: Run auto-installer
echo.
echo [Installing FFmpeg...]
echo.

if not exist "setup-ffmpeg.ps1" (
    echo [ERROR] setup-ffmpeg.ps1 is missing from this folder.
    echo Please re-download the complete package from GitHub.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "setup-ffmpeg.ps1"

:: Verify installation succeeded
if not exist "ffmpeg.exe" (
    echo.
    echo [ERROR] FFmpeg installation failed.
    echo.
    goto :manual_install
)

echo.
echo [SUCCESS] FFmpeg installed!
echo.
timeout /t 2 >nul
goto :ffmpeg_found

:manual_install
echo.
echo ==========================================
echo   Manual Installation Instructions
echo ==========================================
echo.
echo 1. Go to: https://www.gyan.dev/ffmpeg/builds/
echo 2. Download: "ffmpeg-release-essentials.zip"
echo 3. Extract the ZIP file
echo 4. Copy ffmpeg.exe and ffprobe.exe from the bin\ folder
echo 5. Paste them here: %~dp0
echo.
echo Then run this script again.
echo.
pause
exit /b 1

:ffmpeg_found

:: ====================
:: STEP 2: Run Optimizer
:: ====================

if not exist "shrinkwrap.ps1" (
    echo [ERROR] shrinkwrap.ps1 is missing!
    echo Please re-download the complete package from GitHub.
    echo.
    pause
    exit /b 1
)

:: Show usage instructions if no files were dragged
if "%~1"=="" (
    echo [2/2] Ready to compress videos!
    echo.
    echo USAGE:
    echo   1. Drag video files onto this .bat file, OR
    echo   2. This script will process all .mp4 files in the current folder
    echo.
    
    if exist "*.mp4" (
        echo .mp4 files detected in current folder.
        echo.
        choice /C YN /M "Process all videos in this folder now?"
        if errorlevel 2 (
            echo.
            echo Cancelled. Drag specific files onto this .bat file to compress them.
            echo.
            pause
            exit /b 0
        )
        echo.
    ) else (
        echo No .mp4 files found in current folder.
        echo.
        echo TIP: Drag video files onto this .bat file to compress them!
        echo.
        pause
        exit /b 0
    )
)

echo [2/2] Starting video compression...
echo.

:: Run the PowerShell optimizer with all arguments
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "shrinkwrap.ps1" %*

echo.
echo ========================================
echo   Compression Complete!
echo ========================================
echo.
echo Compressed videos are in the "optimized" folder.
echo.

:: Only pause if double-clicked (not drag-and-drop)
if "%~1"=="" pause