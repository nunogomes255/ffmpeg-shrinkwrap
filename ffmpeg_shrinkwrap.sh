#!/bin/bash
# Constraint-Driven MP4 Optimizer for Discord

set -e # Fail fast on error.

# --- CLI Interface & Argument Parsing ---
usage() {
    echo "Usage: $0 [options] [files...]"
    echo "Options:"
    echo "  -p <preset>     FFmpeg x265 preset (default: slow)"
    echo "  -t <size_mb>    Target file size in MB (default: 9.8)"
    echo "  -v <kbps>       Minimum video bitrate floor (default: 500)"
    echo "  -a <kbps>       Minimum audio bitrate floor (default: 64)"
    echo "  -r <retries>    Max encoding retries per pass (default: 3)"
    echo "  -n              No cleanup - preserve logs/artifacts for debugging"
    echo "  -h              Display help"
    echo ""
    echo "Processes *.mp4 files if none specified."
}

preset="slow"
target_size_mb=9.8
min_video_bitrate_kbps=500
min_audio_bitrate_kbps=64
max_retries=3
cleanup=1 # Default: Clean artifacts on exit.

while getopts "p:t:v:a:r:nh" opt; do
    case $opt in
        p) preset="$OPTARG" ;;
        t) target_size_mb="$OPTARG" ;;
        v) min_video_bitrate_kbps="$OPTARG" ;;
        a) min_audio_bitrate_kbps="$OPTARG" ;;
        r) max_retries="$OPTARG" ;;
        n) cleanup=0 ;; # Debug mode enabled
        h) usage; exit 0 ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# --- Configuration Constants ---
MAX_SIZE_MB=10.0
INITIAL_AUDIO_BITRATE_KBPS=192
OVERHEAD_KB=200
OUTPUT_DIR="./optimized"
SUMMARY_FILE="optimization_summary.txt"

# --- Reporting Structures ---
declare -a PROCESSED_FILES=()
declare -a ORIGINAL_SIZES=()
declare -a FINAL_SIZES=()
declare -a REDUCTIONS=()
declare -a STATUSES=()

# --- Utility Functions ---

bail_out() { # Fatal error handler.
    echo -e "\nERROR: $1" >&2
    exit 1
}

check_dependencies() { # Verify runtime environment.
    for cmd in ffmpeg ffprobe bc awk; do
        command -v "$cmd" >/dev/null || bail_out "Dependency missing: $cmd. Install it."
    done
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

get_duration() { # Extract stream duration via ffprobe.
    local file="$1"
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null
}

record_summary() { # Append entry to session report.
    local file="$1" orig_size="$2" final_size="$3" status="$4"
    PROCESSED_FILES+=("$file")
    ORIGINAL_SIZES+=("$orig_size")
    FINAL_SIZES+=("$final_size")
    reduction="N/A"
    
    if [[ "$orig_size" != "N/A" ]] && (( $(echo "$orig_size > 0" | bc -l) )) && [[ "$final_size" != "N/A" ]]; then
        reduction=$(echo "scale=2; (($orig_size - $final_size) / $orig_size) * 100" | bc -l)
    fi

    REDUCTIONS+=("$reduction")
    STATUSES+=("$status")
}

rescue_video() { # Fallback Strategy: Downscale to 720p to maintain bitrate density.
    local input_file="$1"
    local part_suffix="${2:-}"
    local filename=$(basename "$input_file" .mp4)
    local output_file="${OUTPUT_DIR}/${filename}${part_suffix}_optimized.mp4"
    local passlog="${OUTPUT_DIR}/rescue_pass_$$_${RANDOM}"
    
    echo "  [Rescue] Bitrate constraints unsatisfiable at 1080p. Engaging fallback..."

    # --- 1. Calculate Target Bitrate ---
    local duration=$(get_duration "$input_file")
    local target_size_bytes=$(echo "$target_size_mb * 1024 * 1024" | bc -l)
    local overhead_bytes=$(echo "$OVERHEAD_KB * 1024" | bc -l)
    
    local est_audio_bytes=$(echo "$min_audio_bitrate_kbps * 1000 * $duration / 8" | bc -l)
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

        ffmpeg -y -i "$input_file" -pass 1 -passlogfile "$passlog" -c:v libx265 -b:v "${current_video_kbps}k" -preset "$preset" \
            -vf "scale='min(1920,iw)':-2" -an -f null /dev/null 2>"${OUTPUT_DIR}/rescue_1080p_pass1_error_${filename}.txt" && \
        ffmpeg -y -i "$input_file" -pass 2 -passlogfile "$passlog" -c:v libx265 -b:v "${current_video_kbps}k" -preset "$preset" \
            -vf "scale='min(1920,iw)':-2" -c:a aac -b:a "${min_audio_bitrate_kbps}k" -ac 2 -map_metadata 0 -movflags +faststart "$output_file" 2>"${OUTPUT_DIR}/rescue_1080p_pass2_error_${filename}.txt"

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
    # Using the last calculated safe bitrate, ensuring it respects the floor
    if (( $(echo "$current_video_kbps < $min_video_bitrate_kbps" | bc -l) )); then
        current_video_kbps=$min_video_bitrate_kbps
    fi

    retries=0
    while [ $retries -lt $max_retries ]; do
        echo "  [Rescue] 720p Attempt $((retries + 1)): Target ~${current_video_kbps}kbps..."

        ffmpeg -y -i "$input_file" -pass 1 -passlogfile "$passlog" -c:v libx265 -b:v "${current_video_kbps}k" -preset "$preset" \
            -vf "scale='min(1280,iw)':-2" -an -f null /dev/null 2>"${OUTPUT_DIR}/rescue_720p_pass1_error_${filename}.txt" && \
        ffmpeg -y -i "$input_file" -pass 2 -passlogfile "$passlog" -c:v libx265 -b:v "${current_video_kbps}k" -preset "$preset" \
            -vf "scale='min(1280,iw)':-2" -c:a aac -b:a "${min_audio_bitrate_kbps}k" -ac 2 -map_metadata 0 -movflags +faststart "$output_file" 2>"${OUTPUT_DIR}/rescue_720p_pass2_error_${filename}.txt"

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
            echo "  [Rescue] 720p bitrate floor reached. Aborting."
            break
        fi
        retries=$((retries + 1))
    done

    echo "  [Rescue] Failed all attempts. Logs preserved in $OUTPUT_DIR."
    rm -f "${passlog}"-* 2>/dev/null
    return 1
}

split_video() { # Temporal Segmentation: Split video at nearest keyframe.
    local input_file="$1" part_suffix="$2"
    local filename=$(basename "$input_file" .mp4)
    local duration=$(get_duration "$input_file") || { record_summary "$filename$part_suffix" "$(get_file_size_mb "$input_file")" "N/A" "Split Duration Fail"; return 1; }

    # --- Pre-flight check ---
    if (( $(echo "$duration < 25.0" | bc -l) )); then
        # If duration is trivial, splitting is non-viable. Route to Rescue.
        rescue_video "$input_file" "$part_suffix"
        return $?
    fi
    # ------------------------

    duration=$(printf "%.3f" "$duration")
    local half_duration=$(echo "$duration / 2" | bc -l)

    # Locate nearest keyframe to midpoint
    local keyframe_time=$(ffprobe -v error -select_streams v:0 -show_frames -show_entries frame=pkt_pts_time -of csv=p=0 -read_intervals "%+#1" "$input_file" 2>/dev/null | awk -v half="$half_duration" '$1 < half {print $1}' | tail -n 1)

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
    local filename=$(basename "$input_file" .mp4)
    local output_file="${OUTPUT_DIR}/${filename}${part_suffix}_optimized.mp4"
    local temp_file="${OUTPUT_DIR}/${filename}${part_suffix}_temp_$$_${RANDOM}.mp4"
    local passlog="${OUTPUT_DIR}/ffmpeg2pass_$$_${RANDOM}"
    mkdir -p "$OUTPUT_DIR"

    local orig_size_mb=$(get_file_size_mb "$input_file") || { record_summary "$filename$part_suffix" "N/A" "N/A" "Size Check Fail"; return 1; }

    if (( $(echo "$orig_size_mb == 0" | bc -l) )); then
        echo "Skipping zero-byte input: $input_file"
        record_summary "$filename$part_suffix" "0" "N/A" "Empty Input"
        return 1
    fi
    
    echo "Processing: $input_file (Original: ${orig_size_mb}MB)"

    if (( $(echo "$orig_size_mb < $MAX_SIZE_MB" | bc -l) )); then # Input already satisfies constraints
        cp "$input_file" "$output_file" || { record_summary "$filename$part_suffix" "$orig_size_mb" "N/A" "Copy Fail"; return 1; }
        record_summary "$filename$part_suffix" "$orig_size_mb" "$orig_size_mb" "Copied"
        echo "Copied: $output_file"
        return 0
    fi

    local duration=$(get_duration "$input_file") || { record_summary "$filename$part_suffix" "$orig_size_mb" "N/A" "Duration Fail"; return 1; }
    duration=$(printf "%.3f" "$duration")

    local audio_bitrate_kbps=$INITIAL_AUDIO_BITRATE_KBPS
    local target_size_bytes=$(echo "$target_size_mb * 1024 * 1024" | bc -l)
    local overhead_bytes=$(echo "$OVERHEAD_KB * 1024" | bc -l)

    # Bitrate Derivation: (Target - Audio - Overhead) / Duration
    local est_audio_bytes=$(echo "$audio_bitrate_kbps * 1000 * $duration / 8" | bc -l)
    local target_video_bytes=$(echo "$target_size_bytes - $est_audio_bytes - $overhead_bytes" | bc -l)
    local video_bitrate_bps=$(echo "$target_video_bytes * 8 / $duration" | bc -l)
    video_bitrate_bps=$(printf "%.0f" "$video_bitrate_bps") 

    if [ "$video_bitrate_bps" -lt $((min_video_bitrate_kbps * 1000)) ]; then
        video_bitrate_bps=$((min_video_bitrate_kbps * 1000))
    fi
    local current_video_bitrate_kbps=$(echo "$video_bitrate_bps / 1000" | bc -l) 

    local retries=0

    while [ $retries -lt $max_retries ]; do

        echo "Attempt $((retries + 1)): Video ~${current_video_bitrate_kbps}kbps, Audio ${audio_bitrate_kbps}kbps"

        if [ "$video_bitrate_bps" -lt $((min_video_bitrate_kbps * 1000)) ]; then
            video_bitrate_bps=$((min_video_bitrate_kbps * 1000))
        fi

        ffmpeg -y -i "$input_file" -pass 1 -passlogfile "$passlog" -c:v libx265 -b:v "${current_video_bitrate_kbps}k" -preset "$preset" -vf "scale='min(1920,iw)':-2" -an -f null /dev/null 2>"${OUTPUT_DIR}/ffmpeg_pass1_error_${filename}${part_suffix}.txt" && \
        ffmpeg -y -i "$input_file" -pass 2 -passlogfile "$passlog" -c:v libx265 -b:v "${current_video_bitrate_kbps}k" -preset "$preset" \
            -vf "scale='min(1920,iw)':-2" -c:a aac -b:a "${audio_bitrate_kbps}k" -ac 2 -map_metadata 0 -movflags +faststart "$temp_file" 2>"${OUTPUT_DIR}/ffmpeg_pass2_error_${filename}${part_suffix}.txt"

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
            record_summary "$filename$part_suffix" "$orig_size_mb" "$final_size_mb" "Optimized"
            echo "Success: $output_file (${final_size_mb}MB)"
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
                if [ "$audio_bitrate_kbps" -gt "$min_audio_bitrate_kbps" ]; then
                    audio_bitrate_kbps=$((audio_bitrate_kbps - 32)) # Step down audio
                    if [ "$audio_bitrate_kbps" -lt "$min_audio_bitrate_kbps" ]; then
                        audio_bitrate_kbps=$min_audio_bitrate_kbps
                    fi
                    echo "  Video bitrate at floor, reducing audio to ${audio_bitrate_kbps}kbps..."
                else
                    echo "  All bitrates at floor. Initiating Split Protocol..."
                    rm -f "$temp_file" "${passlog}"-* 2>/dev/null
                    split_video "$input_file" "$part_suffix"
                    return $?
                fi
            fi
        else
            echo "Max retries exhausted. Initiating Split Protocol..."
            rm -f "$temp_file" "${passlog}"-* 2>/dev/null
            split_video "$input_file" "$part_suffix"
            return $?
        fi
        rm -f "$temp_file" 2>/dev/null # Cleanup for retry
    done
    return 1 # Fallback catch-all
}


# --- Execution Entry Point ---
echo "Initializing optimization pipeline..."

check_dependencies

shopt -s nullglob
files=("$@")
if [ ${#files[@]} -eq 0 ]; then
    files=(*.mp4)
fi

for file in "${files[@]}"; do
    [[ "$file" =~ _optimized\.mp4$ ]] && { echo "Skipping artifact: $file"; continue; }
    [ ! -f "$file" ] && { echo "File not found: $file"; continue; }
    optimize_video "$file"
done


# --- Post-Mortem Report ---
echo "Writing summary to $SUMMARY_FILE..."
{
    printf "%-40s %-12s %-12s %-12s %-15s\n" "File" "Orig Size" "Final Size" "Reduction %" "Status"
    echo "-------------------------------------------------------------------------------------"
    for i in "${!PROCESSED_FILES[@]}"; do
        printf "%-40s %-12s %-12s %-12s %-15s\n" \
            "${PROCESSED_FILES[$i]:0:40}" \
            "${ORIGINAL_SIZES[$i]}" \
            "${FINAL_SIZES[$i]}" \
            "${REDUCTIONS[$i]}" \
            "${STATUSES[$i]}"
    done
} > "$SUMMARY_FILE"

if [ "$cleanup" -eq 1 ]; then
    echo "Cleaning up temporary artifacts..."
    find "$OUTPUT_DIR/" -maxdepth 1 -type f -name "ffmpeg_pass*" -o -name "*_temp_*.mp4" -o -name "ffmpeg_pass*_error_*.txt" -o -name "split_part*_error_*.txt" -delete
fi

echo "Optimization complete. Summary in $SUMMARY_FILE."

exit 0
