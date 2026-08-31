#!/bin/bash

export LC_ALL=C

# NOTE: 'set -e' is intentionally NOT enabled. The pipeline relies on explicit
# return-code checks so a single failing file records its status and the batch
# continues to the next file, with the summary always written at the end.
set -o pipefail # Capture errors even inside pipes

# Resolve the script's own directory (for shrinkwrap.conf); fall back to CWD if unknown.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="."

# Built-in defaults (used when shrinkwrap.conf is absent or a key is missing). The hardware
# order is AV1-hw -> HEVC-hw; h264_* is intentionally absent (reachable only by explicit
# selection, never auto-ranked above libx265). Config's hardware_order/software_order override
# these; mode defaults to software so a config-less run behaves exactly like before.
DEFAULT_MODE="software"
DEFAULT_HARDWARE_ORDER="av1_amf av1_nvenc av1_qsv hevc_amf hevc_nvenc hevc_qsv hevc_videotoolbox"
DEFAULT_SOFTWARE_ORDER="libx265 libx264"

# --- Persisted preferences (shrinkwrap.conf) ----------------------------------
# Format: `key = value`, `#` comments, space-separated lists. Read precedence:
# script-dir -> per-user -> built-in defaults. Write: script-dir, else per-user.
CONFIG_NAME="shrinkwrap.conf"
CONFIG_FOUND=0
CONFIG_MODE=""; CONFIG_HARDWARE_ORDER=""; CONFIG_SOFTWARE_ORDER=""
CONFIG_TARGET_SIZE_MB=""; CONFIG_PRESET=""
CONFIG_NORMALIZE_AUDIO=""; CONFIG_MONO=""; CONFIG_NO_AUDIO=""
CONFIG_AUDIO_BITRATE=""; CONFIG_MIN_AUDIO_BITRATE=""
CONFIG_MIN_VIDEO_BITRATE=""; CONFIG_MAX_RETRIES=""
CONFIG_CRF_RESCUE_VALUE=""; CONFIG_OUTPUT_DIR=""; CONFIG_NO_CLEANUP=""

trim() { # echo $1 with leading/trailing whitespace removed (pure bash, no subprocess)
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

config_user_dir() { # per-user dir: Windows %APPDATA%, else $XDG_CONFIG_HOME, else ~/.config
    if [ -n "${APPDATA:-}" ]; then
        printf '%s' "$APPDATA/ffmpeg-shrinkwrap"
    elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
        printf '%s' "$XDG_CONFIG_HOME/ffmpeg-shrinkwrap"
    else
        printf '%s' "$HOME/.config/ffmpeg-shrinkwrap"
    fi
}

config_read_path() { # echo first existing conf (script-dir, then per-user); empty if none
    if [ -f "$SCRIPT_DIR/$CONFIG_NAME" ]; then
        printf '%s' "$SCRIPT_DIR/$CONFIG_NAME"
    elif [ -f "$(config_user_dir)/$CONFIG_NAME" ]; then
        printf '%s' "$(config_user_dir)/$CONFIG_NAME"
    fi
}

read_config() { # parse the conf at $1 into the CONFIG_* globals (no-op when absent)
    local path="$1" line key value
    [ -z "$path" ] && return 0
    [ -f "$path" ] || return 0
    CONFIG_FOUND=1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"                          # strip a trailing CR (Windows file)
        case "$(trim "$line")" in ''|'#'*) continue ;; esac
        [ "$line" = "${line#*=}" ] && continue        # no '=' on the line -> skip
        key=$(trim "${line%%=*}")
        value=$(trim "${line#*=}")
        case "$key" in
            mode)              CONFIG_MODE="$value" ;;
            hardware_order)    CONFIG_HARDWARE_ORDER="$value" ;;
            software_order)    CONFIG_SOFTWARE_ORDER="$value" ;;
            target_size_mb)    CONFIG_TARGET_SIZE_MB="$value" ;;
            preset)            CONFIG_PRESET="$value" ;;
            normalize_audio)   CONFIG_NORMALIZE_AUDIO="$value" ;;
            mono)              CONFIG_MONO="$value" ;;
            no_audio)          CONFIG_NO_AUDIO="$value" ;;
            audio_bitrate)     CONFIG_AUDIO_BITRATE="$value" ;;
            min_audio_bitrate) CONFIG_MIN_AUDIO_BITRATE="$value" ;;
            min_video_bitrate) CONFIG_MIN_VIDEO_BITRATE="$value" ;;
            max_retries)       CONFIG_MAX_RETRIES="$value" ;;
            crf_rescue_value)  CONFIG_CRF_RESCUE_VALUE="$value" ;;
            output_dir)        CONFIG_OUTPUT_DIR="$value" ;;
            no_cleanup)        CONFIG_NO_CLEANUP="$value" ;;
        esac
    done < "$path"
}

write_config() { # <mode> : write conf (preserving existing settings); echo path, or return 1
    local new_mode="$1"
    local hw_order="${CONFIG_HARDWARE_ORDER:-$DEFAULT_HARDWARE_ORDER}"
    local sw_order="${CONFIG_SOFTWARE_ORDER:-$DEFAULT_SOFTWARE_ORDER}"
    local target_size="${CONFIG_TARGET_SIZE_MB:-19.8}"
    local p_val="${CONFIG_PRESET:-slow}"
    local norm_aud="${CONFIG_NORMALIZE_AUDIO:-false}"
    local mono_val="${CONFIG_MONO:-false}"
    local no_aud="${CONFIG_NO_AUDIO:-false}"
    local aud_bit="${CONFIG_AUDIO_BITRATE:-192}"
    local min_aud="${CONFIG_MIN_AUDIO_BITRATE:-64}"
    local min_vid="${CONFIG_MIN_VIDEO_BITRATE:-500}"
    local max_ret="${CONFIG_MAX_RETRIES:-3}"
    local crf_val="${CONFIG_CRF_RESCUE_VALUE:-28}"
    local out_dir="${CONFIG_OUTPUT_DIR:-optimized}"
    local no_clean="${CONFIG_NO_CLEANUP:-false}"

    local body
    body="# ffmpeg-shrinkwrap preferences.
# Regenerate:  shrinkwrap --config   |   .\\shrinkwrap.ps1 -Config     (or edit by hand)
# Delete this file to return to defaults (software x265, 19.8MB target).
#
# mode: drives encoder choice when no -c/-Encoder flag is given.
#   hardware       - walk hardware_order (GPU); fall back to software_order
#   software       - walk software_order (x265 first)
#   software_x264  - force libx264 (maximum compatibility / legacy)
mode = $new_mode

# Ordered candidates. Each entry is probed; the first that works wins. Reorder/trim freely.
hardware_order = $hw_order
software_order = $sw_order

# --- Compression & Speed Defaults ---
# target_size_mb: target file size in MB (default: 19.8 for Discord 20MB limit)
# preset: x265/universal preset (slow, medium, fast, faster, etc. default: slow)
target_size_mb = $target_size
preset = $p_val

# --- Audio Defaults ---
# normalize_audio: apply EBU R128 loudness normalization (true/false, default: false)
# mono: downmix audio to mono to save budget (true/false, default: false)
# no_audio: strip audio completely (true/false, default: false)
# audio_bitrate: initial audio bitrate in kbps (default: 192)
# min_audio_bitrate: audio bitrate floor in kbps (default: 64)
normalize_audio = $norm_aud
mono = $mono_val
no_audio = $no_aud
audio_bitrate = $aud_bit
min_audio_bitrate = $min_aud

# --- Output & Fallback Options ---
# output_dir: destination directory for compressed videos (default: optimized)
# min_video_bitrate: video bitrate floor in kbps before 720p rescue (default: 500)
# max_retries: max retry attempts per resolution pass (default: 3)
# crf_rescue_value: CRF quality value for Phase 3 rescue pass (default: 28)
# no_cleanup: preserve logs and intermediate pass files (true/false, default: false)
output_dir = $out_dir
min_video_bitrate = $min_vid
max_retries = $max_ret
crf_rescue_value = $crf_val
no_cleanup = $no_clean"
    local sd="$SCRIPT_DIR/$CONFIG_NAME" ud_dir ud
    ud_dir=$(config_user_dir); ud="$ud_dir/$CONFIG_NAME"
    # stderr is redirected *before* the output redirect so a failed `> "$sd"` (unwritable
    # script dir: permission denied, etc.) is suppressed rather than leaking to the terminal.
    if printf '%s\n' "$body" 2>/dev/null > "$sd"; then
        printf '%s' "$sd"; return 0
    elif mkdir -p "$ud_dir" 2>/dev/null && printf '%s\n' "$body" 2>/dev/null > "$ud"; then
        printf '%s' "$ud"; return 0
    fi
    return 1
}

run_config_wizard() { # interactive: prompt for a default encoder, write conf, exit
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        echo "--config needs an interactive terminal" >&2
        exit 1
    fi
    local answer new_mode saved
    echo "First-time setup - choose your default encoder:"
    echo "  [1] Hardware (GPU)    Fast, offloads to GPU. Usually a bit larger / lower-quality at the"
    echo "                        size cap; hardware AV1/HEVC may not play inline on Discord for"
    echo "                        everyone. Falls back to software if no GPU encoder works."
    echo "  [2] Software x265     (Recommended) Best quality at the cap (libx265 2-pass); plays"
    echo "                        inline on Discord. Slower. Falls back to x264."
    echo "  [3] Software x264     Maximum compatibility / legacy. Plays everywhere, larger files."
    printf "Your choice [2]: "
    read -r answer
    case "$answer" in
        1) new_mode="hardware" ;;
        3) new_mode="software_x264" ;;
        *) new_mode="software" ;;                      # empty Enter / anything else -> default
    esac
    if saved=$(write_config "$new_mode"); then
        echo "Saved to $saved."
        exit 0
    fi
    echo "ERROR: could not write config (script dir and per-user dir both unwritable)." >&2
    exit 1
}

# --- CLI Interface & Argument Parsing ---
usage() {
    echo "Usage: $0 [options] [files...]"
    echo "Options:"
    echo "  -c <encoder>    Encoder: auto (default, software 2-pass), hw (probe GPU"
    echo "                  hierarchy), or a specific encoder (e.g. hevc_nvenc, av1_amf,"
    echo "                  h264_qsv) - functionally validated, falls back to software"
    echo "  -p <preset>     FFmpeg x265 preset (default: slow)"
    echo "  -t <size_mb>    Target file size in MB (default: 19.8)"
    echo "  -v <kbps>       Minimum video bitrate floor (default: 500)"
    echo "  -a <kbps>       Minimum audio bitrate floor (default: 64)"
    echo "  -r <retries>    Max encoding retries per pass (default: 3)"
    echo "  -o <dir>        Output directory (default: optimized)"
    echo "  -n              No cleanup - preserve logs/artifacts for debugging"
    echo "  -l              Normalize audio loudness (EBU R128 / -16 LUFS, two-pass)"
    echo "  -m              Downmix audio to mono (frees budget on voice-only clips)"
    echo "  -A              Remove audio entirely (-an); frees the whole budget for video"
    echo "  -h              Display help"
    echo "  --config        Interactive setup: pick a default encoder, save shrinkwrap.conf,"
    echo "                  then exit (no files processed). Re-run anytime to reconfigure."
    echo ""
    echo "Examples:"
    echo "  $0                                      # Process all videos in current directory"
    echo "  $0 clip.mp4                             # Process a specific file"
    echo "  $0 -t 49 -p medium clip.mp4             # Target 50MB Discord Nitro Basic"
    echo "  $0 -c hw clip.mp4                       # Auto-pick best working GPU encoder"
    echo "  $0 -c hevc_nvenc clip.mp4               # Force NVIDIA NVENC HEVC encoder"
    echo "  $0 -l -m clip.mp4                       # Normalize loudness and downmix to mono"
    echo "  $0 -A clip.mp4                          # Strip audio entirely to maximize video quality"
    echo "  $0 --config                             # Run interactive encoder setup wizard"
    echo ""
    echo "Processes common video files (mp4/mkv/mov/avi/webm/m4v/flv) if none specified."
    echo "Preference file shrinkwrap.conf (script dir, else per-user) sets the default encoder"
    echo "when no -c flag is given; -c always overrides it for that run."
}

# Pre-load configuration so config values act as default arguments
read_config "$(config_read_path)"

MODE="${CONFIG_MODE:-$DEFAULT_MODE}"
HARDWARE_ORDER="${CONFIG_HARDWARE_ORDER:-$DEFAULT_HARDWARE_ORDER}"
SOFTWARE_ORDER="${CONFIG_SOFTWARE_ORDER:-$DEFAULT_SOFTWARE_ORDER}"

preset="${CONFIG_PRESET:-slow}"
encoder_choice="auto" # auto = software 2-pass (default); hw = probe GPU; or an encoder name
encoder_explicit=0 # Track whether -c was user-set (distinguishes a config-driven default)
target_size_mb="${CONFIG_TARGET_SIZE_MB:-19.8}"
min_video_bitrate_kbps="${CONFIG_MIN_VIDEO_BITRATE:-500}"
min_audio_bitrate_kbps="${CONFIG_MIN_AUDIO_BITRATE:-64}"
max_retries="${CONFIG_MAX_RETRIES:-3}"
cleanup="$([ "${CONFIG_NO_CLEANUP:-}" = "true" ] && echo 0 || echo 1)" # Default: Clean artifacts on exit
normalize_audio="$([ "${CONFIG_NORMALIZE_AUDIO:-}" = "true" ] && echo 1 || echo 0)"
audio_channels="$([ "${CONFIG_MONO:-}" = "true" ] && echo 1 || echo 2)"
remove_audio="$([ "${CONFIG_NO_AUDIO:-}" = "true" ] && echo 1 || echo 0)"
OUTPUT_DIR="${CONFIG_OUTPUT_DIR:-optimized}"
INITIAL_AUDIO_BITRATE_KBPS="${CONFIG_AUDIO_BITRATE:-192}"
CRF_RESCUE_VALUE="${CONFIG_CRF_RESCUE_VALUE:-28}"

# getopts has no long-option support, so pre-scan "$@" for --config, set a flag, and drop
# it from the positional parameters before getopts runs over the remaining short options.
do_config=0
pruned_args=()
for arg in "$@"; do
    if [ "$arg" = "--config" ]; then
        do_config=1
    else
        pruned_args+=("$arg")
    fi
done
set -- "${pruned_args[@]}"

while getopts "c:p:t:v:a:r:o:nhlmA" opt; do
    case $opt in
        c) encoder_choice="$OPTARG"; encoder_explicit=1 ;;
        p) preset="$OPTARG" ;;
        t) target_size_mb="$OPTARG" ;;
        v) min_video_bitrate_kbps="$OPTARG" ;;
        a) min_audio_bitrate_kbps="$OPTARG" ;;
        r) max_retries="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        n) cleanup=0 ;; # Debug mode enabled
        l) normalize_audio=1 ;; # Enable audio normalization
        m) audio_channels=1 ;; # Downmix audio to mono
        A) remove_audio=1 ;; # Strip audio entirely (-an)
        h) usage; exit 0 ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# --- Configuration Constants ---
MAX_SIZE_MB=$(echo "$target_size_mb" | awk '{print ($1 > int($1) ? int($1)+1 : int($1))}')
[ -z "$MAX_SIZE_MB" ] || [ "$MAX_SIZE_MB" -lt 1 ] && MAX_SIZE_MB=20
OVERHEAD_KB=200
MAX_VIDEO_BITRATE_KBPS=50000
SUMMARY_FILE="optimization_summary.txt"

# --- UI: colors + glyphs (degrade to plain ASCII when piped or NO_COLOR is set) ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
    G_OK="✓"; G_FAIL="✗"; G_ARROW="►"; G_BOX="📦"; G_HLINE="─"; G_HEAVY="═"
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
    G_OK="[OK]"; G_FAIL="[x]"; G_ARROW=">"; G_BOX="#"; G_HLINE="-"; G_HEAVY="="
fi

ui_rule() { # <glyph> <width> : print a horizontal rule
    local glyph="${1:-$G_HLINE}" width="${2:-60}" line="" i
    for ((i=0; i<width; i++)); do line+="$glyph"; done
    printf "%s%s%s\n" "$C_DIM" "$line" "$C_RESET"
}

ui_banner() { # <target_mb> <codec> <preset> <audio_mode>
    echo ""
    printf "%s%s%s %sffmpeg-shrinkwrap%s  Discord video compressor\n" "$C_CYAN" "$G_BOX" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf "%s  target <= %s MB  |  codec %s  |  preset %s  |  audio %s%s\n" "$C_DIM" "$1" "$2" "$3" "$4" "$C_RESET"
    ui_rule "$G_HEAVY"
}

ui_file_header() { # <index> <total> <name>
    echo ""
    printf "%s%s [%s/%s]%s %s%s%s\n" "$C_CYAN" "$G_ARROW" "$1" "$2" "$C_RESET" "$C_BOLD" "$3" "$C_RESET"
}

fmt_elapsed() { printf "%dm %02ds" $(( $1 / 60 )) $(( $1 % 60 )); }

say_info() { printf "%s%s%s\n" "$C_CYAN" "$1" "$C_RESET"; }
say_ok()   { printf "%s%s %s%s\n" "$C_GREEN" "$G_OK" "$1" "$C_RESET"; }

ui_tally() { # <total_in_mb> <total_out_mb> <elapsed_str> : console-only batch summary
    local total_in="$1" total_out="$2" elapsed="$3"
    local n_opt=0 n_copy=0 n_rescue=0 n_split=0 n_fail=0 record status
    for record in "${REPORT_RECORDS[@]}"; do
        IFS="$REPORT_SEP" read -r _ _ _ _ status <<< "$record"
        case "$status" in
            Optimized)            n_opt=$((n_opt+1)) ;;
            Copied)               n_copy=$((n_copy+1)) ;;
            Rescued*)             n_rescue=$((n_rescue+1)) ;;
            Split)                n_split=$((n_split+1)) ;;
            *Fail*|"Empty Input") n_fail=$((n_fail+1)) ;;
        esac
    done
    local pct="0.0" in_disp out_disp
    if (( $(echo "$total_in > 0" | bc -l) )); then
        pct=$(echo "scale=1; (($total_in - $total_out) / $total_in) * 100" | bc -l)
    fi
    in_disp=$(printf "%.2f" "$total_in" 2>/dev/null) || in_disp="$total_in"
    out_disp=$(printf "%.2f" "$total_out" 2>/dev/null) || out_disp="$total_out"
    echo ""
    ui_rule "$G_HEAVY"
    printf "%s%s Done%s in %s\n" "$C_BOLD$C_GREEN" "$G_OK" "$C_RESET" "$elapsed"
    printf "  %s%s %s optimized%s, %s copied, %s rescued, %s split, %s%s %s failed%s\n" \
        "$C_GREEN" "$G_OK" "$n_opt" "$C_RESET" "$n_copy" "$n_rescue" "$n_split" "$C_RED" "$G_FAIL" "$n_fail" "$C_RESET"
    printf "  %sTotal: %s MB -> %s MB  (%s%% smaller)%s\n" "$C_CYAN" "$in_disp" "$out_disp" "$pct" "$C_RESET"
    ui_rule "$G_HEAVY"
}

# --- Audio Normalization Cache ---
declare -A AUDIO_NORM_CACHE

# --- Reporting Structures ---
# A single delimited-record array (one append per file) instead of five parallel
# arrays, so a column can never silently desync from the others.
REPORT_SEP=$'\x1f' # ASCII Unit Separator: never appears in filenames/sizes/status
declare -a REPORT_RECORDS=()

# --- Utility Functions ---

bail_out() { # Fatal error handler.
    echo -e "\nERROR: $1" >&2
    exit 1
}

# Crash Cleanup

cleanup_artifacts() {
    if [ "$cleanup" -eq 1 ] && [ -d "$OUTPUT_DIR" ]; then
        # Changed pattern to "*pass*" to catch both ffmpeg2pass and rescue_pass logs
        find "$OUTPUT_DIR/" -maxdepth 1 -type f \( -name "*pass*" -o -name "*_temp_*.mp4" -o -name "*_error_*.txt" -o -name "*_loudnorm_*.json" \) -delete 2>/dev/null
    fi
}


on_interrupt() {
    echo -e "\n\n[!] Script interrupted by user. Cleaning up partial files..."
    cleanup_artifacts
    echo "Cleanup complete. Exiting."
    exit 130
}

# Catch Ctrl+C (SIGINT) and Termination (SIGTERM)
trap on_interrupt SIGINT SIGTERM

# Parses -progress pipe:1 output to calculate percentage
run_with_progress() {
    local desc="$1"
    local duration="$2"
    shift 2
    local cmd=("$@")

    tput civis # Hide cursor

    # Run command, pipe progress to loop, send errors to /dev/null (or log file in calls)
    "${cmd[@]}" -progress pipe:1 | while IFS= read -r line; do
        if [[ "$line" == "out_time_us="* ]]; then
            local current_us=${line#out_time_us=}
            
            if [ "$duration" != "0" ] && [ "$current_us" != "N/A" ]; then
                # Calculate Percentage
                local pct=$(awk -v c="$current_us" -v d="$duration" 'BEGIN { printf "%.0f", (c / (d * 1000000)) * 100 }')
                # Clamp to 100
                if [ "$pct" -gt 100 ]; then pct=100; fi

                # Draw Bar
                local width=20
                local filled=$(awk -v p="$pct" -v w="$width" 'BEGIN { printf "%.0f", (p / 100) * w }')
                local empty=$((width - filled))
                
                local bar=""
                # Append # for filled
                for ((i=0; i<filled; i++)); do bar+="#"; done
                # Append - for empty
                for ((i=0; i<empty; i++)); do bar+="-"; done

                printf "\r  %s [%s] %3d%% " "$desc" "$bar" "$pct"
            fi
        fi
    done

    # Capture exit code of the piped command
    local exit_code=$?
    
    # Restore cursor and newline
    tput cnorm
    echo ""
    
    return $exit_code
}

check_dependencies() { # Verify runtime environment.
    for cmd in ffmpeg ffprobe bc awk; do
        command -v "$cmd" >/dev/null || bail_out "Dependency missing: $cmd. Install it."
    done
}

# Codec availability: word-anchored grep over a *cached* `ffmpeg -encoders` (cheap, so the
# software path keeps its zero-probe overhead -- "compiled in" is enough for software).
ENCODERS_CACHE=""
encoder_available() { # <encoder_name>
    [ -z "$ENCODERS_CACHE" ] && ENCODERS_CACHE=$(ffmpeg -encoders 2>/dev/null)
    printf '%s\n' "$ENCODERS_CACHE" | grep -Fqw -- "$1"
}

# Walk $SOFTWARE_ORDER and echo the first compiled-in entry; libx264 if none match. This is
# the software default's single chokepoint (formerly detect_codec, hardcoded libx265->libx264).
resolve_software() {
    local enc
    for enc in $SOFTWARE_ORDER; do
        if encoder_available "$enc"; then echo "$enc"; return 0; fi
    done
    echo "libx264"
}

# --- Hardware-encoder support (opt-in via -c) ---------------------------------
# Software (libx264/libx265) drives the unchanged 2-pass path; every other family
# is single-pass hardware (no file-based 2-pass, vendor rate-control + presets).
codec_family() { # <encoder_name> -> software|amf|nvenc|qsv|videotoolbox
    case "$1" in
        *_amf)          echo "amf" ;;
        *_nvenc)        echo "nvenc" ;;
        *_qsv)          echo "qsv" ;;
        *_videotoolbox) echo "videotoolbox" ;;
        *)              echo "software" ;;
    esac
}

# --- Preset normalization ------------------------------------------------------
# Any preset the user types (an x264/x265 name OR another vendor's token) is normalized to a
# token valid for whichever encoder is actually selected, so the run never breaks on a syntax
# mismatch. The model is three speed tiers (fast|medium|slow); cross-vendor input is warned
# about once (see warn_preset_mismatch) but still honored.

# Single source of truth for every recognized preset name: echo "<vendor> <tier>".
#   vendor: x264 | amf | nvenc | unknown      tier: fast | medium | slow
# An unrecognized token defaults to the slow tier (the project default).
preset_info() { # <preset>
    case "$1" in
        ultrafast|superfast|veryfast|faster|fast) echo "x264 fast" ;;
        medium)                                   echo "x264 medium" ;;
        slow|slower|veryslow|placebo)             echo "x264 slow" ;;
        speed)    echo "amf fast" ;;
        balanced) echo "amf medium" ;;
        quality)  echo "amf slow" ;;
        p1|p2|p3) echo "nvenc fast" ;;
        p4|p5)    echo "nvenc medium" ;;
        p6|p7)    echo "nvenc slow" ;;
        *)        echo "unknown slow" ;;
    esac
}

# Translate a slow|medium|fast tier into the family's native preset/quality token.
hw_preset() { # <family> <tier>
    case "$1" in
        amf)   case "$2" in slow) echo "quality" ;; medium) echo "balanced" ;; fast) echo "speed" ;; esac ;;
        nvenc) case "$2" in slow) echo "p7" ;;      medium) echo "p5" ;;       fast) echo "p3" ;;    esac ;;
        qsv)   echo "$2" ;;          # qsv preset names are slow/medium/fast/... already
        *)     echo "" ;;            # videotoolbox: no preset knob
    esac
}

# True (0) when preset $2 (vendor $3) is already valid for family $1, so it passes through
# verbatim (preserving full x264/qsv/nvenc granularity). amf is intentionally absent: its
# tokens round-trip the tier map, so translating them yields the identical token anyway.
preset_native() { # <family> <preset> <vendor>
    case "$1" in
        software) [ "$3" = x264 ] ;;
        nvenc)    [ "$3" = nvenc ] ;;
        qsv)      case "$2" in veryfast|faster|fast|medium|slow|slower|veryslow) return 0 ;; *) return 1 ;; esac ;;
        *)        return 1 ;;        # amf (round-trips) + videotoolbox (no preset knob)
    esac
}

# Resolve any preset string to a token valid for <family>: verbatim if native, else translated
# via its speed tier (preset_info already supplies the slow-tier default for unknown tokens).
resolve_preset_token() { # <family> <preset>
    local family="$1" raw="$2" vendor tier
    read -r vendor tier <<< "$(preset_info "$raw")"
    preset_native "$family" "$raw" "$vendor" && { echo "$raw"; return; }
    [ "$family" = software ] && { echo "$tier"; return; }
    hw_preset "$family" "$tier"
}

# Warn once if the user's preset isn't native to the selected family, then show the per-encoder
# guide. x264/x265 names are the universal input and never warn (so the default 'slow' is silent).
warn_preset_mismatch() { # <family> <raw_preset> <resolved_token>
    local family="$1" raw="$2" resolved="$3" vendor _tier
    [ "$family" = videotoolbox ] && return 0          # no preset knob -> nothing to warn about
    read -r vendor _tier <<< "$(preset_info "$raw")"
    case "$vendor" in
        x264)      return 0 ;;                         # universal language (already translated)
        "$family") return 0 ;;                         # native vendor token (amf/nvenc)
    esac
    if [ "$vendor" = unknown ]; then
        printf "%s  [Preset] Unrecognized preset '%s'; using '%s' for %s.%s\n" "$C_YELLOW" "$raw" "$resolved" "$family" "$C_RESET" >&2
    else
        printf "%s  [Preset] '%s' is a %s preset but the active encoder is %s; using '%s'.%s\n" "$C_YELLOW" "$raw" "$vendor" "$family" "$resolved" "$C_RESET" >&2
    fi
    printf "%s  Preset guide (any of these works; it is mapped to the active encoder):%s\n" "$C_DIM" "$C_RESET" >&2
    printf "%s    software (libx264/libx265): ultrafast superfast veryfast faster fast medium slow slower veryslow placebo%s\n" "$C_DIM" "$C_RESET" >&2
    printf "%s    amf:   quality(slow) balanced(medium) speed(fast)%s\n" "$C_DIM" "$C_RESET" >&2
    printf "%s    nvenc: p7/p6(slow) p5/p4(medium) p3/p2/p1(fast)%s\n" "$C_DIM" "$C_RESET" >&2
    printf "%s    qsv:   veryfast faster fast medium slow slower veryslow%s\n" "$C_DIM" "$C_RESET" >&2
}

# Emit the family-correct single-pass video rate-control + preset flags, space-separated
# (no token contains a space, so callers can word-split safely).
#   mode = bitrate -> capped VBR at the target bitrate X, maxrate X, bufsize 2X
#   mode = cq      -> constant-quality rescue (replaces -crf 28), capped by maxrate
build_hw_video_args() { # <family> <mode> <bitrate_kbps> <maxrate_kbps>
    local family="$1" mode="$2" bitrate maxrate
    # bc -l yields fractional kbps (e.g. 6522.163); round to integer so bash arithmetic
    # (bufsize) and the ffmpeg rate tokens stay clean. Sub-kbps precision is meaningless.
    bitrate=$(printf "%.0f" "$3")
    maxrate=$(printf "%.0f" "$4")
    local bufsize=$((maxrate * 2))
    local vp
    vp=$(resolve_preset_token "$family" "$preset")    # valid for this family, whatever was typed
    case "$family" in
        nvenc)
            printf -- "-rc vbr -multipass fullres"
            [ -n "$vp" ] && printf -- " -preset %s" "$vp"
            if [ "$mode" = cq ]; then
                printf -- " -cq %s -b:v 0 -maxrate %sk -bufsize %sk" "${CRF_RESCUE_VALUE:-28}" "$maxrate" "$bufsize"
            else
                printf -- " -b:v %sk -maxrate %sk -bufsize %sk" "$bitrate" "$maxrate" "$bufsize"
            fi
            ;;
        amf)
            printf -- "-rc vbr_peak"
            [ -n "$vp" ] && printf -- " -quality %s" "$vp"
            # AMF has no stable constant-quality flag across builds -> capped VBR; in cq
            # mode the budget (maxrate) is the target so it can't overshoot.
            if [ "$mode" = cq ]; then
                printf -- " -b:v %sk -maxrate %sk -bufsize %sk" "$maxrate" "$maxrate" "$bufsize"
            else
                printf -- " -b:v %sk -maxrate %sk -bufsize %sk" "$bitrate" "$maxrate" "$bufsize"
            fi
            ;;
        qsv)
            [ -n "$vp" ] && printf -- "-preset %s " "$vp"
            if [ "$mode" = cq ]; then
                printf -- "-global_quality %s -maxrate %sk -bufsize %sk" "${CRF_RESCUE_VALUE:-28}" "$maxrate" "$bufsize"
            else
                printf -- "-b:v %sk -maxrate %sk -bufsize %sk" "$bitrate" "$maxrate" "$bufsize"
            fi
            ;;
        videotoolbox)
            # No preset knob and no stable CQ flag -> capped VBR; cq mode targets the budget.
            if [ "$mode" = cq ]; then
                printf -- "-b:v %sk -maxrate %sk -bufsize %sk" "$maxrate" "$maxrate" "$bufsize"
            else
                printf -- "-b:v %sk -maxrate %sk -bufsize %sk" "$bitrate" "$maxrate" "$bufsize"
            fi
            ;;
    esac
}

# Functional probe: a real 1-frame encode with the exact RC template we will use.
# Returns 0 only if the encoder is compiled in AND actually works on this machine
# (compiled-in != usable for hardware, so the name grep alone is not trustworthy).
probe_encoder() { # <encoder>
    local enc="$1" family
    family=$(codec_family "$enc")
    local -a rc=()
    if [ "$family" = software ]; then
        rc=(-b:v 1M)
    else
        # shellcheck disable=SC2206
        rc=($(build_hw_video_args "$family" bitrate 1000 1000))
    fi
    ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=s=256x144:d=0.1 -frames:v 1 \
        -c:v "$enc" "${rc[@]}" -f null - >/dev/null 2>&1
}

select_encoder() { # Sets globals VIDEO_CODEC + CODEC_FAMILY + CODEC_SOURCE.
    local choice enc
    # 1. Per-run -c flag wins; else derive the choice from config mode; else built-in default.
    if [ "$encoder_explicit" -eq 1 ]; then
        choice="$encoder_choice"
        CODEC_SOURCE="-c flag"
    elif [ "$CONFIG_FOUND" -eq 1 ]; then
        case "$MODE" in
            hardware)      choice="hw" ;;
            software)      choice="auto" ;;
            software_x264) choice="software_x264" ;;
            *)             choice="auto" ;;            # unknown mode -> safe software default
        esac
        CODEC_SOURCE="config: $MODE"
    else
        choice="auto"
        CODEC_SOURCE="default"
    fi

    # 2. Resolve the choice to a concrete encoder.
    case "$choice" in
        auto)
            VIDEO_CODEC=$(resolve_software)            # software list via cheap grep
            ;;
        software_x264)
            if encoder_available libx264; then
                VIDEO_CODEC="libx264"
            else
                VIDEO_CODEC=$(resolve_software)
            fi
            ;;
        hw)
            say_info "  [Encoder] Probing hardware encoders..."
            VIDEO_CODEC=""
            for enc in $HARDWARE_ORDER; do
                if probe_encoder "$enc"; then VIDEO_CODEC="$enc"; break; fi
            done
            if [ -z "$VIDEO_CODEC" ]; then
                VIDEO_CODEC=$(resolve_software)
                printf "%s  [Encoder] No working hardware encoder found; using software (%s).%s\n" "$C_YELLOW" "$VIDEO_CODEC" "$C_RESET"
            else
                say_ok "[Encoder] Hardware encoder: $VIDEO_CODEC"
            fi
            ;;
        *)
            if probe_encoder "$choice"; then
                VIDEO_CODEC="$choice"
                say_ok "[Encoder] Using $VIDEO_CODEC"
            else
                VIDEO_CODEC=$(resolve_software)
                printf "%s  [Encoder] '%s' failed validation; falling back to software (%s).%s\n" "$C_YELLOW" "$choice" "$VIDEO_CODEC" "$C_RESET"
            fi
            ;;
    esac
    CODEC_FAMILY=$(codec_family "$VIDEO_CODEC")
}

# Audio output flags for an encode: -an when audio is stripped (-A), else AAC at <kbps> with
# the optional loudnorm filter + channel layout. No token contains a space, so the unquoted
# command substitution at the software call sites word-splits correctly. (Relies on bash
# dynamic scope to read the caller's $audio_filter_args / $audio_channels.)
audio_out_args() { # <bitrate_kbps>
    if [ "$remove_audio" -eq 1 ]; then
        printf -- "-an"
    else
        printf -- "-c:a aac -b:a %sk %s -ac %s" "$1" "$audio_filter_args" "$audio_channels"
    fi
}

# Bytes to reserve for audio in the size budget: 0 when audio is stripped, else <kbps>*dur.
audio_budget_bytes() { # <bitrate_kbps> <duration_sec>
    if [ "$remove_audio" -eq 1 ]; then echo 0; else echo "$1 * 1000 * $2 / 8" | bc -l; fi
}

# Single-pass hardware encode that plugs into the same run_with_progress + size-check
# flow as the software 2-pass blocks. Scale / AAC audio / faststart mirror the software
# path exactly; only the video rate-control differs.
hw_encode() { # <input> <desc> <duration> <mode> <bitrate> <maxrate> <scale> <audio_kbps> <output> [audio_filter_args...]
    local input="$1" desc="$2" duration="$3" mode="$4" bitrate="$5" maxrate="$6" scale="$7" abitrate="$8" output="$9"
    shift 9
    local audio_filter=("$@")
    local logf="${OUTPUT_DIR}/$(basename_noext "$output")_hwpass_error.txt"
    local vargs
    # shellcheck disable=SC2206
    vargs=($(build_hw_video_args "$CODEC_FAMILY" "$mode" "$bitrate" "$maxrate"))
    local -a aout
    if [ "$remove_audio" -eq 1 ]; then
        aout=(-an)
    else
        aout=(-c:a aac -b:a "${abitrate}k" "${audio_filter[@]}" -ac "$audio_channels")
    fi
    run_with_progress "$desc" "$duration" ffmpeg -y -i "$input" $VSYNC_FLAG \
        -c:v "$VIDEO_CODEC" -pix_fmt yuv420p "${vargs[@]}" \
        -vf "$scale" "${aout[@]}" \
        -map_metadata 0 -movflags +faststart "$output" 2>"$logf"
}

detect_vsync_flag() { # Determines if we should use the modern -fps_mode or legacy -vsync
    if ffmpeg -version 2>&1 | grep -qE "ffmpeg version [5-9]\.|ffmpeg version [1-9][0-9]\."; then
        echo "-fps_mode cfr"
    else
        echo "-vsync 1"
    fi
}

basename_noext() { # Strip directory and the last extension (any container, not just .mp4).
    local b="${1##*/}"
    echo "${b%.*}"
}

get_file_size_mb() { # Return file size in MB with decimal precision.
    local file="$1"
    [ ! -f "$file" ] && { echo "File not found: $file" >&2; return 1; }
    if [ ! -s "$file" ]; then
        echo "0"
        return 0
    fi
    size_bytes=$(wc -c < "$file") || return 1
    echo "scale=3; $size_bytes / 1048576" | bc -l
}

get_duration() { # Extract duration via ffprobe (container first, then video stream).
    local file="$1" dur
    dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    if [ -z "$dur" ] || [ "$dur" = "N/A" ]; then
        # Fallback: some containers carry duration only on the stream, not the format.
        dur=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    fi
    if [ -z "$dur" ] || [ "$dur" = "N/A" ]; then
        return 1 # Signal "unknown duration" to callers
    fi
    echo "$dur"
}

# Two-pass audio normalization analysis
analyze_audio_loudness() {
    local input_file="$1"
    local cache_key=$(basename "$input_file")
    
    # Check if already analyzed
    if [ -n "${AUDIO_NORM_CACHE[$cache_key]}" ]; then
        echo "${AUDIO_NORM_CACHE[$cache_key]}"
        return 0
    fi
    
    local json_file="${OUTPUT_DIR}/$(basename_noext "$input_file")_loudnorm_$$_${RANDOM}.json"
    
    echo "  [Audio Analysis] Measuring loudness (two-pass mode)..." >&2
    
    # Run loudnorm analysis pass
    ffmpeg -i "$input_file" -af loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json -f null - 2>&1 | \
        grep -A 12 "Parsed_loudnorm" | grep -A 12 "{" > "$json_file"
    
    if [ ! -s "$json_file" ]; then
        echo "  [Warning] Audio analysis failed, falling back to single-pass" >&2
        rm -f "$json_file"
        echo ""
        return 1
    fi
    
    # Parse JSON using grep and sed (no jq dependency needed)
    local input_i=$(grep '"input_i"' "$json_file" | sed 's/.*: "\(.*\)".*/\1/' | tr -d ' ')
    local input_tp=$(grep '"input_tp"' "$json_file" | sed 's/.*: "\(.*\)".*/\1/' | tr -d ' ')
    local input_lra=$(grep '"input_lra"' "$json_file" | sed 's/.*: "\(.*\)".*/\1/' | tr -d ' ')
    local input_thresh=$(grep '"input_thresh"' "$json_file" | sed 's/.*: "\(.*\)".*/\1/' | tr -d ' ')
    local target_offset=$(grep '"target_offset"' "$json_file" | sed 's/.*: "\(.*\)".*/\1/' | tr -d ' ')
    
    rm -f "$json_file"
    
    # Validate we got all values
    if [ -z "$input_i" ] || [ -z "$input_tp" ] || [ -z "$input_lra" ] || [ -z "$input_thresh" ] || [ -z "$target_offset" ]; then
        echo "  [Warning] Failed to parse loudness data, falling back to single-pass" >&2
        echo ""
        return 1
    fi
    
    echo "  [Audio Analysis] Measured: ${input_i} LUFS (target: -16 LUFS)" >&2
    
    # Build the two-pass filter string
    local filter="loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=${input_i}:measured_TP=${input_tp}:measured_LRA=${input_lra}:measured_thresh=${input_thresh}:offset=${target_offset}:linear=true"
    
    # Cache the result
    AUDIO_NORM_CACHE[$cache_key]="$filter"
    
    echo "$filter"
    return 0
}

get_audio_filter() {
    local input_file="$1"
    
    if [ "$normalize_audio" -eq 0 ]; then
        echo ""
        return 0
    fi
    
    # Try two-pass analysis
    local filter=$(analyze_audio_loudness "$input_file")
    
    if [ -z "$filter" ]; then
        # Fallback to single-pass if analysis fails
        echo "loudnorm=I=-16:TP=-1.5:LRA=11"
    else
        echo "$filter"
    fi
}

record_summary() { # Append one delimited record to the session report.
    local file="$1" orig_size="$2" final_size="$3" status="$4"
    local reduction="N/A"

    if [[ "$orig_size" != "N/A" ]] && (( $(echo "$orig_size > 0" | bc -l) )) && [[ "$final_size" != "N/A" ]]; then
        reduction=$(echo "scale=2; (($orig_size - $final_size) / $orig_size) * 100" | bc -l)
    fi

    REPORT_RECORDS+=("${file}${REPORT_SEP}${orig_size}${REPORT_SEP}${final_size}${REPORT_SEP}${reduction}${REPORT_SEP}${status}")
}

rescue_video() { # Fallback Strategy: Downscale to 720p to maintain bitrate density.
    local input_file="$1"
    local part_suffix="${2:-}"
    local orig_size_mb="$3"
    local filename=$(basename_noext "$input_file")
    local output_file="${OUTPUT_DIR}/${filename}${part_suffix}_optimized.mp4"
    local temp_file="${OUTPUT_DIR}/${filename}${part_suffix}_temp_$$_${RANDOM}.mp4"
    local passlog="${OUTPUT_DIR}/rescue_pass_$$_${RANDOM}"
    
    # Get audio filter (two-pass if enabled)
    local audio_filter_args=""
    if [ "$normalize_audio" -eq 1 ] && [ "$remove_audio" -eq 0 ]; then
        local filter=$(get_audio_filter "$input_file")
        if [ -n "$filter" ]; then
            audio_filter_args="-af $filter"
        fi
    fi
    
    echo "  [Rescue] Bitrate constraints unsatisfiable at 1080p. Engaging fallback..."

    # --- 1. Calculate Target Bitrate ---
    local duration=$(get_duration "$input_file")
    local target_size_bytes=$(echo "$target_size_mb * 1024 * 1024" | bc -l)
    local overhead_bytes=$(echo "$OVERHEAD_KB * 1024" | bc -l)
    
    local est_audio_bytes=$(audio_budget_bytes "$min_audio_bitrate_kbps" "$duration")
    local target_video_bytes=$(echo "$target_size_bytes - $est_audio_bytes - $overhead_bytes" | bc -l)
    local video_bitrate_bps=$(echo "$target_video_bytes * 8 / $duration" | bc -l)
    video_bitrate_bps=$(printf "%.0f" "$video_bitrate_bps")

    local current_video_kbps=$(echo "$video_bitrate_bps / 1000" | bc -l)

    # Enforce bitrate floor
    if [ "$video_bitrate_bps" -lt $((min_video_bitrate_kbps * 1000)) ]; then
        echo "  [Rescue] Calculated bitrate violates floor. Clamping to minimum ($min_video_bitrate_kbps kbps)."
        current_video_kbps=$min_video_bitrate_kbps
    fi

    # --- 2. Phase 1: 1080p Loop (Retries) ---
    local retries=0
    
    while [ $retries -lt $max_retries ]; do
        echo "  [Rescue] Attempt $((retries + 1)) (1080p): Re-encoding @ ~${current_video_kbps}kbps..."

        if [ "$CODEC_FAMILY" = software ]; then
        run_with_progress "Pass 1" "$duration" ffmpeg -y -i "$input_file" $VSYNC_FLAG -pass 1 -passlogfile "$passlog" -c:v "$VIDEO_CODEC" -pix_fmt yuv420p -b:v "${current_video_kbps}k" -preset "$preset" \
            -vf "scale='min(1920,iw)':-2" -an -f null /dev/null 2>"${OUTPUT_DIR}/rescue_1080p_pass1_error_${filename}.txt" && \
        run_with_progress "Pass 2" "$duration" ffmpeg -y -i "$input_file" $VSYNC_FLAG -pass 2 -passlogfile "$passlog" -c:v "$VIDEO_CODEC" -pix_fmt yuv420p -b:v "${current_video_kbps}k" -preset "$preset" \
            -vf "scale='min(1920,iw)':-2" $(audio_out_args "${min_audio_bitrate_kbps}") -map_metadata 0 -movflags +faststart "$output_file" 2>"${OUTPUT_DIR}/rescue_1080p_pass2_error_${filename}.txt"
        else
            hw_encode "$input_file" "Encode" "$duration" bitrate "$current_video_kbps" "$current_video_kbps" "scale='min(1920,iw)':-2" "$min_audio_bitrate_kbps" "$output_file" $audio_filter_args
        fi

        local final_size=$(get_file_size_mb "$output_file")

        # Validation
        if (( $(echo "$final_size <= $target_size_mb" | bc -l) )) && (( $(echo "$final_size > 0" | bc -l) )); then
            record_summary "$filename" "$(get_file_size_mb "$input_file")" "$final_size" "Rescued (1080p)"
            echo "  [Rescue] Success: $output_file ($final_size MB) - Native Resolution Preserved"
            rm -f "${passlog}"-* 2>/dev/null
            return 0
        fi

        # Convergence Logic
        echo "  [Rescue] 1080p result exceeds target ($final_size MB). Adjusting..."
        
        local overshoot_ratio=$(echo "scale=3; $final_size / $target_size_mb" | bc -l)

        if (( $(echo "$overshoot_ratio < 1.05" | bc -l) )); then
            overshoot_ratio=1.05
        fi

        local new_video_bitrate_kbps=$(echo "scale=0; $current_video_kbps / $overshoot_ratio" | bc -l)
        current_video_kbps=$new_video_bitrate_kbps

        # Floor check
        if (( $(echo "$current_video_kbps < $min_video_bitrate_kbps" | bc -l) )); then
            echo "  [Rescue] Bitrate floor reached. Initiating 720p downscale."
            break
        fi

        retries=$((retries + 1))
    done

    # --- 3. Phase 2: Force 720p (Fallback) ---
    echo "  [Rescue] 1080p failed. Phase 2: Downscaling to 720p..."

    # Reset bitrate calculation for 720p
    if (( $(echo "$current_video_kbps < $min_video_bitrate_kbps" | bc -l) )); then
        current_video_kbps=$min_video_bitrate_kbps
    fi

    retries=0
    while [ $retries -lt $max_retries ]; do
        echo "  [Rescue] 720p Attempt $((retries + 1)): Target ~${current_video_kbps}kbps..."

        if [ "$CODEC_FAMILY" = software ]; then
        run_with_progress "Pass 1" "$duration" ffmpeg -y -i "$input_file" $VSYNC_FLAG -pass 1 -passlogfile "$passlog" -c:v "$VIDEO_CODEC" -pix_fmt yuv420p -b:v "${current_video_kbps}k" -preset "$preset" \
            -vf "scale='min(1280,iw)':-2" -an -f null /dev/null 2>"${OUTPUT_DIR}/rescue_720p_pass1_error_${filename}.txt" && \
        run_with_progress "Pass 2" "$duration" ffmpeg -y -i "$input_file" $VSYNC_FLAG -pass 2 -passlogfile "$passlog" -c:v "$VIDEO_CODEC" -pix_fmt yuv420p -b:v "${current_video_kbps}k" -preset "$preset" \
            -vf "scale='min(1280,iw)':-2" $(audio_out_args "${min_audio_bitrate_kbps}") -map_metadata 0 -movflags +faststart "$output_file" 2>"${OUTPUT_DIR}/rescue_720p_pass2_error_${filename}.txt"
        else
            hw_encode "$input_file" "Encode" "$duration" bitrate "$current_video_kbps" "$current_video_kbps" "scale='min(1280,iw)':-2" "$min_audio_bitrate_kbps" "$output_file" $audio_filter_args
        fi

        local final_size=$(get_file_size_mb "$output_file")

        if (( $(echo "$final_size <= $target_size_mb" | bc -l) )) && (( $(echo "$final_size > 0" | bc -l) )); then
            record_summary "$filename" "$(get_file_size_mb "$input_file")" "$final_size" "Rescued (720p)"
            echo "  [Rescue] Success: $output_file ($final_size MB) - Downscaled to 720p"
            rm -f "${passlog}"-* 2>/dev/null
            return 0
        fi

        # Adjust for next retry
        local overshoot_ratio=$(echo "scale=3; $final_size / $target_size_mb" | bc -l)

        if (( $(echo "$overshoot_ratio < 1.05" | bc -l) )); then
            overshoot_ratio=1.05
        fi

        local new_kbps=$(echo "scale=0; $current_video_kbps / $overshoot_ratio * 0.9" | bc -l)
        current_video_kbps=${new_kbps%.*}

        if (( $(echo "$current_video_kbps < $min_video_bitrate_kbps" | bc -l) )); then
            echo "  [Rescue] 720p bitrate floor reached."
            break
        fi
        retries=$((retries + 1))
    done

    # --- 4. Phase 3: Last Resort capped CRF rescue @ 720p ---
    local crf_maxrate_kbps=$(echo "scale=0; ($target_size_bytes - $(audio_budget_bytes 64 "$duration") - $overhead_bytes) * 8 / $duration / 1000" | bc -l)
    if [ "$crf_maxrate_kbps" -lt "$min_video_bitrate_kbps" ]; then
        crf_maxrate_kbps=$min_video_bitrate_kbps
    fi
    local crf_bufsize_kbps=$((crf_maxrate_kbps * 2))
    echo "  [Rescue] Phase 3: Last resort capped CRF ${CRF_RESCUE_VALUE:-28} @ 720p (maxrate ${crf_maxrate_kbps}k)..."
    if [ "$CODEC_FAMILY" = software ]; then
    run_with_progress "CRF Pass" "$duration" ffmpeg -y -i "$input_file" $VSYNC_FLAG -c:v "$VIDEO_CODEC" -pix_fmt yuv420p -crf "${CRF_RESCUE_VALUE:-28}" -maxrate "${crf_maxrate_kbps}k" -bufsize "${crf_bufsize_kbps}k" -preset "$preset" \
        -vf "scale='min(1280,iw)':-2" $(audio_out_args 64) -map_metadata 0 -movflags +faststart "$temp_file" 2>/dev/null
    else
        hw_encode "$input_file" "CRF Pass" "$duration" cq "$crf_maxrate_kbps" "$crf_maxrate_kbps" "scale='min(1280,iw)':-2" 64 "$temp_file" $audio_filter_args
    fi

    local crf_size=$(get_file_size_mb "$temp_file")

    if (( $(echo "$crf_size <= $target_size_mb" | bc -l) )) && (( $(echo "$crf_size > 0" | bc -l) )); then
        mv "$temp_file" "$output_file"
        record_summary "$filename" "$(get_file_size_mb "$input_file")" "$crf_size" "Rescued (CRF)"
        echo "  [Rescue] Success (CRF): $output_file ($crf_size MB)"
        rm -f "${passlog}"-* 2>/dev/null
        return 0
    fi
    
    echo "  [Rescue] All rescue attempts failed. Logs preserved in $OUTPUT_DIR."
    rm -f "$temp_file" "${passlog}"-* 2>/dev/null
    return 1
}



split_video() { # Temporal Segmentation: Split video at nearest keyframe.
    local input_file="$1" part_suffix="$2" 
    local filename=$(basename_noext "$input_file")
    local duration
    duration=$(get_duration "$input_file") || { record_summary "$filename$part_suffix" "$(get_file_size_mb "$input_file")" "N/A" "Split Duration Fail"; return 1; }

    # --- Pre-flight check ---
    # Calculate if even at minimum bitrates we can't fit
    local absolute_min_video_bytes=$(echo "$min_video_bitrate_kbps * 1000 * $duration / 8" | bc -l)
    local absolute_min_audio_bytes=$(audio_budget_bytes "$min_audio_bitrate_kbps" "$duration")
    local absolute_min_total=$(echo "($absolute_min_video_bytes + $absolute_min_audio_bytes) / 1048576" | bc -l)

    # If mathematically impossible, proceed with split (below)
    # If rescue might work, try that instead
    if (( $(echo "$absolute_min_total <= $target_size_mb" | bc -l) )); then
        echo "  Video might fit with rescue mode. Attempting rescue before split..."
        if rescue_video "$input_file" "$part_suffix" "$orig_size_mb"; then
            return 0
        fi
        echo "  Rescue failed. Falling back to keyframe split..."
    fi
    # Continue with actual split logic...
    echo "  Video too long for target size even at minimum bitrates. Must split."
    duration=$(printf "%.3f" "$duration")
    local half_duration=$(echo "$duration / 2" | bc -l)

    # Locate nearest keyframe to midpoint
    # Scan packet flags for the last keyframe (flag "K") before the midpoint.
    local keyframe_time=$(ffprobe -v error -select_streams v:0 -show_packets -show_entries packet=pts_time,flags -of csv=p=0 "$input_file" 2>/dev/null | awk -F',' -v half="$half_duration" '$1 != "N/A" && $2 ~ /K/ && ($1 + 0) < half { print $1 }' | tail -n 1)

    local split_point="$half_duration" # Fallback to geometric center

    if [ -n "$keyframe_time" ]; then
        if (( $(echo "$keyframe_time > 0.5" | bc -l) )); then
            split_point="$keyframe_time"
            echo "Split point (keyframe): ${split_point}s"
        else
            echo "Split point (keyframe deviation too high), defaulting to geometric center: ${split_point}s"
        fi
    else
        echo "Split point (keyframe search failed), defaulting to geometric center: ${split_point}s"
    fi

    local part1_suffix="${part_suffix}_PART_1"
    local part2_suffix="${part_suffix}_PART_2"
    local part1_file="${OUTPUT_DIR}/${filename}${part1_suffix}_temp_$$_${RANDOM}.mp4"
    local part2_file="${OUTPUT_DIR}/${filename}${part2_suffix}_temp_$$_${RANDOM}.mp4"

    echo "Splitting $input_file at ${split_point}s..."
    ffmpeg -y -i "$input_file" -t "$split_point" -c copy -avoid_negative_ts 1 "$part1_file" 2>"${OUTPUT_DIR}/split_part1_error_${filename}${part_suffix}.txt" && \
    ffmpeg -y -i "$input_file" -ss "$split_point" -c copy -avoid_negative_ts 1 "$part2_file" 2>"${OUTPUT_DIR}/split_part2_error_${filename}${part_suffix}.txt"

    if [ $? -ne 0 ]; then
        echo "Split failed. Logs in $OUTPUT_DIR." >&2
        rm -f "$part1_file" "$part2_file" 2>/dev/null
        record_summary "$filename$part_suffix" "$(get_file_size_mb "$input_file")" "N/A" "Split Fail"
        return 1
    fi

    if [ ! -s "$part1_file" ] || [ ! -s "$part2_file" ]; then
        echo "Split produced zero-byte artifacts. Aborting." >&2
        rm -f "$part1_file" "$part2_file" 2>/dev/null
        record_summary "$filename$part_suffix" "$(get_file_size_mb "$input_file")" "N/A" "Split Fail"
        return 1
    fi

    # Recursively optimize the segments
    optimize_video "$part1_file" "$part1_suffix" && optimize_video "$part2_file" "$part2_suffix"
    local split_status=$?
    rm -f "$part1_file" "$part2_file" 2>/dev/null
    if [ $split_status -eq 0 ]; then
        record_summary "$filename$part_suffix" "$(get_file_size_mb "$input_file")" "N/A" "Split"
    fi
    return $split_status
}


optimize_video() { # Primary Optimization Pipeline: 2-Pass HEVC Encoding.
    local input_file="$1" part_suffix="${2:-}"
    local filename=$(basename_noext "$input_file")
    local output_file="${OUTPUT_DIR}/${filename}${part_suffix}_optimized.mp4"
    local temp_file="${OUTPUT_DIR}/${filename}${part_suffix}_temp_$$_${RANDOM}.mp4"
    local passlog="${OUTPUT_DIR}/ffmpeg2pass_$$_${RANDOM}"
    mkdir -p "$OUTPUT_DIR"
    
    # Get audio filter (two-pass if enabled)
    local audio_filter_args=""
    if [ "$normalize_audio" -eq 1 ] && [ "$remove_audio" -eq 0 ]; then
        local filter=$(get_audio_filter "$input_file")
        if [ -n "$filter" ]; then
            audio_filter_args="-af $filter"
        fi
    fi

    local orig_size_mb=$(get_file_size_mb "$input_file") || { record_summary "$filename$part_suffix" "N/A" "N/A" "Size Check Fail"; return 1; }

    if (( $(echo "$orig_size_mb == 0" | bc -l) )); then
        echo "Skipping zero-byte input: $input_file"
        record_summary "$filename$part_suffix" "0" "N/A" "Empty Input"
        return 1
    fi
    
    say_info "Processing: $input_file (Original: ${orig_size_mb}MB)"

    if (( $(echo "$orig_size_mb < $MAX_SIZE_MB" | bc -l) )); then # Input already satisfies constraints
        if [ "$remove_audio" -eq 1 ]; then
            # Honor -A even on the no-encode fast path: stream-copy the video and drop audio
            # (lossless, no re-encode); fall back to a plain copy if the container can't remux.
            ffmpeg -y -i "$input_file" -c copy -an -movflags +faststart "$output_file" 2>/dev/null \
                || cp "$input_file" "$output_file" || { record_summary "$filename$part_suffix" "$orig_size_mb" "N/A" "Copy Fail"; return 1; }
            record_summary "$filename$part_suffix" "$orig_size_mb" "$(get_file_size_mb "$output_file")" "Copied"
        else
            cp "$input_file" "$output_file" || { record_summary "$filename$part_suffix" "$orig_size_mb" "N/A" "Copy Fail"; return 1; }
            record_summary "$filename$part_suffix" "$orig_size_mb" "$orig_size_mb" "Copied"
        fi
        echo "Copied: $output_file"
        return 0
    fi

    local duration
    duration=$(get_duration "$input_file") || { record_summary "$filename$part_suffix" "$orig_size_mb" "N/A" "Duration Fail"; return 1; }
    duration=$(printf "%.3f" "$duration")

    local audio_bitrate_kbps=$INITIAL_AUDIO_BITRATE_KBPS
    local target_size_bytes=$(echo "$target_size_mb * 1024 * 1024" | bc -l)
    local overhead_bytes=$(echo "$OVERHEAD_KB * 1024" | bc -l)

    # Bitrate Derivation: (Target - Audio - Overhead) / Duration
    local est_audio_bytes=$(audio_budget_bytes "$audio_bitrate_kbps" "$duration")
    local target_video_bytes=$(echo "$target_size_bytes - $est_audio_bytes - $overhead_bytes" | bc -l)
    local video_bitrate_bps=$(echo "$target_video_bytes * 8 / $duration" | bc -l)
    video_bitrate_bps=$(printf "%.0f" "$video_bitrate_bps") 

    if [ "$video_bitrate_bps" -gt $((MAX_VIDEO_BITRATE_KBPS * 1000)) ]; then
        echo "  [Info] Calculated bitrate ($((video_bitrate_bps/1000))k) is overkill. Capping at ${MAX_VIDEO_BITRATE_KBPS}k."
        video_bitrate_bps=$((MAX_VIDEO_BITRATE_KBPS * 1000))
    fi

    if [ "$video_bitrate_bps" -lt $((min_video_bitrate_kbps * 1000)) ]; then
        video_bitrate_bps=$((min_video_bitrate_kbps * 1000))
    fi
    local current_video_bitrate_kbps=$(echo "$video_bitrate_bps / 1000" | bc -l)
    local upward_correction_done=0 # Reclaim-headroom guard (bidirectional convergence runs once)

    local retries=0

    while [ $retries -lt $max_retries ]; do

        echo "Attempt $((retries + 1)): Video ~${current_video_bitrate_kbps}kbps, Audio ${audio_bitrate_kbps}kbps"

        if [ "$video_bitrate_bps" -lt $((min_video_bitrate_kbps * 1000)) ]; then
            video_bitrate_bps=$((min_video_bitrate_kbps * 1000))
        fi

        if [ "$CODEC_FAMILY" = software ]; then
        run_with_progress "Pass 1" "$duration" ffmpeg -y -i "$input_file" $VSYNC_FLAG -pass 1 -passlogfile "$passlog" -c:v "$VIDEO_CODEC" -pix_fmt yuv420p -b:v "${current_video_bitrate_kbps}k" -preset "$preset" \
            -vf "scale='min(1920,iw)':-2" -an -f null /dev/null 2>"${OUTPUT_DIR}/ffmpeg_pass1_error_${filename}${part_suffix}.txt" && \
        run_with_progress "Pass 2" "$duration" ffmpeg -y -i "$input_file" $VSYNC_FLAG -pass 2 -passlogfile "$passlog" -c:v "$VIDEO_CODEC" -pix_fmt yuv420p -b:v "${current_video_bitrate_kbps}k" -preset "$preset" \
            -vf "scale='min(1920,iw)':-2" $(audio_out_args "${audio_bitrate_kbps}") -map_metadata 0 -movflags +faststart "$temp_file" 2>"${OUTPUT_DIR}/ffmpeg_pass2_error_${filename}${part_suffix}.txt"
        else
            hw_encode "$input_file" "Encode" "$duration" bitrate "$current_video_bitrate_kbps" "$current_video_bitrate_kbps" "scale='min(1920,iw)':-2" "$audio_bitrate_kbps" "$temp_file" $audio_filter_args
        fi

        if [ $? -ne 0 ]; then
            echo "Encoding failed (Attempt $((retries + 1))). Logs in $OUTPUT_DIR." >&2
            rm -f "$temp_file" "${passlog}"-* 2>/dev/null
            record_summary "$filename$part_suffix" "$orig_size_mb" "N/A" "Encode Fail"
            return 1
        fi

        local final_size_mb=$(get_file_size_mb "$temp_file") || final_size_mb="N/A"
        echo "  Result: ${final_size_mb}MB"

        if (( $(echo "$final_size_mb <= $MAX_SIZE_MB" | bc -l) )); then
            mv "$temp_file" "$output_file"

            # Bidirectional convergence: if we landed well under target, reclaim the
            # unused headroom once by re-encoding upward (ABR otherwise only lowers).
            if [ "$upward_correction_done" -eq 0 ] && [[ "$final_size_mb" != "N/A" ]] && \
               (( $(echo "$final_size_mb > 0 && $final_size_mb < $target_size_mb * 0.9" | bc -l) )); then
                upward_correction_done=1
                local prev_good_size="$final_size_mb"
                local upward_kbps=$(echo "scale=0; $current_video_bitrate_kbps * $target_size_mb / $final_size_mb" | bc -l)
                if [ "$upward_kbps" -gt "$MAX_VIDEO_BITRATE_KBPS" ]; then
                    upward_kbps=$MAX_VIDEO_BITRATE_KBPS
                fi
                echo "  Result well under target (${final_size_mb}MB). Reclaiming headroom @ ~${upward_kbps}kbps..."

                if [ "$CODEC_FAMILY" = software ]; then
                run_with_progress "Pass 1" "$duration" ffmpeg -y -i "$input_file" $VSYNC_FLAG -pass 1 -passlogfile "$passlog" -c:v "$VIDEO_CODEC" -pix_fmt yuv420p -b:v "${upward_kbps}k" -preset "$preset" \
                    -vf "scale='min(1920,iw)':-2" -an -f null /dev/null 2>"${OUTPUT_DIR}/ffmpeg_pass1_error_${filename}${part_suffix}.txt" && \
                run_with_progress "Pass 2" "$duration" ffmpeg -y -i "$input_file" $VSYNC_FLAG -pass 2 -passlogfile "$passlog" -c:v "$VIDEO_CODEC" -pix_fmt yuv420p -b:v "${upward_kbps}k" -preset "$preset" \
                    -vf "scale='min(1920,iw)':-2" $(audio_out_args "${audio_bitrate_kbps}") -map_metadata 0 -movflags +faststart "$temp_file" 2>"${OUTPUT_DIR}/ffmpeg_pass2_error_${filename}${part_suffix}.txt"
                else
                    hw_encode "$input_file" "Encode" "$duration" bitrate "$upward_kbps" "$upward_kbps" "scale='min(1920,iw)':-2" "$audio_bitrate_kbps" "$temp_file" $audio_filter_args
                fi

                if [ $? -eq 0 ]; then
                    local upward_size_mb=$(get_file_size_mb "$temp_file")
                    # Keep the upward result only if it stayed within the hard cap and is
                    # genuinely closer to target (larger) than the result we already have.
                    if (( $(echo "$upward_size_mb <= $MAX_SIZE_MB && $upward_size_mb > $prev_good_size" | bc -l) )); then
                        mv "$temp_file" "$output_file"
                        final_size_mb="$upward_size_mb"
                        echo "  Headroom reclaimed: ${final_size_mb}MB"
                    else
                        echo "  Upward retry (${upward_size_mb}MB) not usable; keeping ${prev_good_size}MB result."
                        rm -f "$temp_file" 2>/dev/null
                    fi
                else
                    echo "  Upward retry failed; keeping ${prev_good_size}MB result."
                    rm -f "$temp_file" 2>/dev/null
                fi
            fi

            record_summary "$filename$part_suffix" "$orig_size_mb" "$final_size_mb" "Optimized"
            say_ok "Success: $output_file (${final_size_mb}MB)"
            rm -f "${passlog}"-* 2>/dev/null
            return 0
        fi

        retries=$((retries + 1))
        if [ "$retries" -lt "$max_retries" ]; then
            echo "  Result exceeds target (${final_size_mb}MB > ${MAX_SIZE_MB}MB). Recalculating..."

            # Adaptive Rate Control: Reduce bitrate proportional to overshoot
            local overshoot_ratio=$(echo "scale=3; $final_size_mb / $MAX_SIZE_MB" | bc -l)
            local new_video_bitrate_kbps=$(echo "scale=0; $current_video_bitrate_kbps / $overshoot_ratio" | bc -l) 
            current_video_bitrate_kbps=$new_video_bitrate_kbps

            if (( $(echo "$current_video_bitrate_kbps < $min_video_bitrate_kbps" | bc -l) )); then
                current_video_bitrate_kbps=$min_video_bitrate_kbps
                if [ "$remove_audio" -eq 0 ] && [ "$audio_bitrate_kbps" -gt "$min_audio_bitrate_kbps" ]; then
                    audio_bitrate_kbps=$((audio_bitrate_kbps - 32)) # Step down audio
                    if [ "$audio_bitrate_kbps" -lt "$min_audio_bitrate_kbps" ]; then
                        audio_bitrate_kbps=$min_audio_bitrate_kbps
                    fi
                    echo "  Video bitrate at floor, reducing audio to ${audio_bitrate_kbps}kbps..."
                else
                    echo "  All bitrates at floor. Initiating Fallback Protocol..."
                    break
                fi
            fi
        else
            echo "Max retries exhausted. Initiating Fallback Protocol..."
            break
        fi
        rm -f "$temp_file" 2>/dev/null # Cleanup for retry
    done
    
    # CRF Rescue (capped): CRF rescue quality with a VBV cap so it cannot overshoot the
    # target, and isn't artificially size-limited when the content is easy.
    local crf_maxrate_kbps=$(echo "scale=0; ($target_size_bytes - $(audio_budget_bytes 64 "$duration") - $overhead_bytes) * 8 / $duration / 1000" | bc -l)
    if [ "$crf_maxrate_kbps" -lt "$min_video_bitrate_kbps" ]; then
        crf_maxrate_kbps=$min_video_bitrate_kbps
    fi
    local crf_bufsize_kbps=$((crf_maxrate_kbps * 2))
    echo "  [Info] Attempting capped CRF ${CRF_RESCUE_VALUE:-28} rescue (maxrate ${crf_maxrate_kbps}k) before splitting..."

    if [ "$CODEC_FAMILY" = software ]; then
    run_with_progress "CRF Pass" "$duration" ffmpeg -y -i "$input_file" $VSYNC_FLAG -c:v "$VIDEO_CODEC" -pix_fmt yuv420p -crf "${CRF_RESCUE_VALUE:-28}" -maxrate "${crf_maxrate_kbps}k" -bufsize "${crf_bufsize_kbps}k" -preset "$preset" \
        -vf "scale='min(1920,iw)':-2" $(audio_out_args 64) -map_metadata 0 -movflags +faststart "$temp_file" 2>/dev/null
    else
        hw_encode "$input_file" "CRF Pass" "$duration" cq "$crf_maxrate_kbps" "$crf_maxrate_kbps" "scale='min(1920,iw)':-2" 64 "$temp_file" $audio_filter_args
    fi

    local crf_size_mb=$(get_file_size_mb "$temp_file")
    
    if (( $(echo "$crf_size_mb <= $MAX_SIZE_MB" | bc -l) )) && (( $(echo "$crf_size_mb > 0" | bc -l) )); then
        mv "$temp_file" "$output_file"
        record_summary "$filename$part_suffix" "$orig_size_mb" "$crf_size_mb" "Rescued (CRF)"
        echo "Success (CRF Rescue): $output_file (${crf_size_mb}MB)"
        rm -f "${passlog}"-* 2>/dev/null
        return 0
    fi
    
    echo "  [Info] CRF pass failed (${crf_size_mb}MB). Proceeding to split..."
    rm -f "$temp_file" "${passlog}"-* 2>/dev/null
    
    split_video "$input_file" "$part_suffix"
    
    return $?
}


# --- Execution Entry Point ---
SECONDS=0 # Bash builtin stopwatch for the end-of-run tally

# `--config` is pure setup: run the wizard, write the conf, and exit before any processing
# (and before check_dependencies, so it works even where bc/ffmpeg are absent).
[ "$do_config" -eq 1 ] && run_config_wizard

check_dependencies
VSYNC_FLAG=$(detect_vsync_flag)
select_encoder # Sets VIDEO_CODEC + CODEC_FAMILY + CODEC_SOURCE (flag > config > default)

# Normalize the preset to a token valid for the encoder we landed on (warn once on a
# cross-vendor mismatch), so any preset string runs as intended on any encoder.
preset_resolved=$(resolve_preset_token "$CODEC_FAMILY" "$preset")
warn_preset_mismatch "$CODEC_FAMILY" "$preset" "$preset_resolved"
preset="$preset_resolved"

if [ "$remove_audio" -eq 1 ]; then
    audio_mode="none"
else
    audio_mode=$([ "$normalize_audio" -eq 1 ] && echo "normalized" || echo "default")
    [ "$audio_channels" -eq 1 ] && audio_mode="${audio_mode}, mono"
fi
ui_banner "$target_size_mb" "$VIDEO_CODEC ($CODEC_SOURCE)" "$preset" "$audio_mode"

shopt -s nullglob nocaseglob
files=("$@")
if [ ${#files[@]} -eq 0 ]; then
    files=(*.mp4 *.mkv *.mov *.avi *.webm *.m4v *.flv)
fi

if [ ${#files[@]} -eq 0 ] || [ ! -f "${files[0]}" ]; then
    bail_out "No supported video files found in current directory."
fi

# Build the top-level work list once, so the [i/N] counter and batch totals are accurate
# and recursive split-parts never inflate them.
to_process=()
for file in "${files[@]}"; do
    [[ "$file" =~ _optimized\.mp4$ ]] && { printf "%sSkipping artifact: %s%s\n" "$C_DIM" "$file" "$C_RESET"; continue; }
    [ ! -f "$file" ] && { printf "%sFile not found: %s%s\n" "$C_YELLOW" "$file" "$C_RESET"; continue; }
    to_process+=("$file")
done

total_files=${#to_process[@]}
total_in_mb=0
idx=0
for file in "${to_process[@]}"; do
    idx=$((idx + 1))
    ui_file_header "$idx" "$total_files" "$(basename "$file")"
    fsize=$(get_file_size_mb "$file" 2>/dev/null) || fsize=0
    total_in_mb=$(echo "$total_in_mb + $fsize" | bc -l)
    optimize_video "$file"
done


# --- Post-Mortem Report ---
printf "%sWriting summary to %s...%s\n" "$C_DIM" "$SUMMARY_FILE" "$C_RESET"
{
    printf "%-40s %-12s %-12s %-12s %-15s\n" "File" "Orig Size" "Final Size" "Reduction %" "Status"
    echo "-------------------------------------------------------------------------------------"
    for record in "${REPORT_RECORDS[@]}"; do
        IFS="$REPORT_SEP" read -r rec_file rec_orig rec_final rec_red rec_status <<< "$record"
        printf "%-40s %-12s %-12s %-12s %-15s\n" \
            "${rec_file:0:40}" "$rec_orig" "$rec_final" "$rec_red" "$rec_status"
    done
} > "$SUMMARY_FILE"

# Batch tally (console only; the summary file written above is intentionally unchanged).
total_out_mb=0
for record in "${REPORT_RECORDS[@]}"; do
    IFS="$REPORT_SEP" read -r _ _ rec_final _ _ <<< "$record"
    if [[ "$rec_final" != "N/A" ]] && (( $(echo "$rec_final > 0" | bc -l) )); then
        total_out_mb=$(echo "$total_out_mb + $rec_final" | bc -l)
    fi
done
ui_tally "$total_in_mb" "$total_out_mb" "$(fmt_elapsed "$SECONDS")"

cleanup_artifacts

exit 0
