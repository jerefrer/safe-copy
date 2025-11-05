#!/bin/bash
# STEP 2: HASH BOTH DRIVES IN PARALLEL (RESUMABLE)
# Creates SHA256 hash manifests for source and destination with resume support

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <source_disk> <drive_name> <destination_path>"
    echo "Example: $0 /dev/disk4s2 \"Project_2015\" /Volumes/Exos24TB"
    echo ""
    echo "This script creates hash manifests for both source and destination drives"
    echo "Note: Ensure source disk is mounted (read-only recommended)"
    echo "This script is RESUMABLE - you can stop and restart it anytime"
    exit 1
fi

SOURCE_DISK=$1
DRIVE_NAME=$2
DEST_BASE=$3

DEST_DIR="$DEST_BASE/$DRIVE_NAME"
LOG_DIR="$DEST_BASE/_logs"
MANIFEST_DIR="$DEST_BASE/_manifests"

# Function to check for UPS emergency shutdown
check_ups_shutdown() {
    if [ -f "/tmp/ups_emergency_shutdown" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🚨 UPS EMERGENCY SHUTDOWN DETECTED - Stopping operations!"
        echo "   Power failure or low battery condition detected"
        exit 130  # SIGINT exit code
    fi
}

# Function to start UPS monitoring
start_ups_monitor() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local ups_monitor="$script_dir/ups-monitor.sh"
    
    if [ -f "$ups_monitor" ] && [ -x "$ups_monitor" ]; then
        # Check if UPS is present
        if pmset -g batt | grep -qF -- "-1500"; then
            echo "🔋 UPS detected - Starting UPS monitoring in background"
            $ups_monitor &
            UPS_MONITOR_PID=$!
            echo $UPS_MONITOR_PID > "/tmp/ups_monitor.pid"
            echo "UPS Monitor PID: $UPS_MONITOR_PID"
        else
            echo "ℹ️  No UPS detected - continuing without power monitoring"
        fi
    else
        echo "⚠️  UPS Monitor not found - continuing without power monitoring"
    fi
}

# Function to stop UPS monitoring
stop_ups_monitor() {
    if [ -f "/tmp/ups_monitor.pid" ]; then
        local ups_pid=$(cat "/tmp/ups_monitor.pid")
        if kill -0 $ups_pid 2>/dev/null; then
            echo "Stopping UPS Monitor (PID: $ups_pid)"
            kill $ups_pid 2>/dev/null || true
        fi
        rm -f "/tmp/ups_monitor.pid"
    fi
}

# Function to detect hash algorithm from manifest
detect_hash_algorithm() {
    local manifest_file="$1"

    if [ -f "$manifest_file" ]; then
        # Check manifest header for algorithm
        local header=$(head -n 2 "$manifest_file" | grep "%%%")
        if echo "$header" | grep -q "blake2b"; then
            echo "blake2b"
        elif echo "$header" | grep -q "sha256"; then
            echo "sha256"
        else
            # Default to sha256 if header unclear
            echo "sha256"
        fi
    else
        # No manifest yet - prefer BLAKE2 for new manifests
        echo "blake2b"
    fi
}

# Function to get hash command for algorithm
get_hash_command() {
    local algorithm="$1"

    if [ "$algorithm" = "blake2b" ]; then
        if command -v b2sum &> /dev/null; then
            echo "b2sum"
        else
            echo "ERROR: BLAKE2 algorithm selected but b2sum not found. Install via: brew install coreutils" >&2
            exit 1
        fi
    else
        # SHA256
        if command -v sha256sum &> /dev/null; then
            echo "sha256sum"
        elif command -v shasum &> /dev/null; then
            echo "shasum -a 256"
        else
            echo "ERROR: Neither sha256sum nor shasum found. Please install coreutils." >&2
            exit 1
        fi
    fi
}

# Function to detect if drive is SSD or HDD
detect_drive_type() {
    local disk_device="$1"

    # Extract base disk (e.g., /dev/disk5s2 -> /dev/disk5)
    local base_disk=$(echo "$disk_device" | sed 's/s[0-9]*$//')

    # Check if solid state
    local is_ssd=$(diskutil info "$base_disk" 2>/dev/null | grep "Solid State" | grep -i "yes")

    if [ -n "$is_ssd" ]; then
        echo "SSD"
    else
        echo "HDD"
    fi
}

# Function to get optimal parallelism based on drive type
get_optimal_parallelism() {
    local drive_type="$1"

    if [ "$drive_type" = "SSD" ]; then
        echo "8"  # SSD: No seek penalty, maximize CPU usage
    else
        echo "3"  # HDD: Minimize seeking, balance speed vs stress
    fi
}

# Check if destination exists
if [ ! -d "$DEST_DIR" ]; then
    echo "ERROR: Destination directory does not exist: $DEST_DIR"
    echo "Please run step1-copy.sh first"
    exit 1
fi

# Find the mount point
MOUNT_POINT=$(diskutil info "$SOURCE_DISK" | grep "Mount Point" | cut -d: -f2 | xargs)

if [ -z "$MOUNT_POINT" ] || [ "$MOUNT_POINT" = "" ]; then
    echo "ERROR: Source disk is not mounted: $SOURCE_DISK"
    echo "Please mount it using Disk Arbitrator (read-only recommended)"
    exit 1
fi

echo "╔════════════════════════════════════════════════╗"
echo "║   STEP 2: RESUMABLE HASH VERIFICATION SETUP   ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
echo "Source: $MOUNT_POINT"
echo "Destination: $DEST_DIR"
echo "Hash command: $HASH_CMD"
echo ""

SOURCE_MANIFEST="$MANIFEST_DIR/${DRIVE_NAME}_source_manifest.txt"
DEST_MANIFEST="$MANIFEST_DIR/${DRIVE_NAME}_manifest.txt"
SOURCE_STATE="$MANIFEST_DIR/${DRIVE_NAME}_source_state.txt"
DEST_STATE="$MANIFEST_DIR/${DRIVE_NAME}_dest_state.txt"
SOURCE_LOG="$LOG_DIR/${DRIVE_NAME}_source_hash.log"
DEST_LOG="$LOG_DIR/${DRIVE_NAME}_dest_hash.log"

# Clean up any stale status files from previous interrupted runs
rm -f "${SOURCE_STATE}.current" "${DEST_STATE}.current" 2>/dev/null

# Worker function to hash a single file (called by parallel workers)
# Exported so it can be called by xargs subshells
hash_single_file() {
    local file="$1"
    local manifest_file="$2"
    local state_file="$3"
    local hash_cmd="$4"
    local drive_label="$5"

    # Get file size
    local size=$(stat -f "%z" "$file" 2>/dev/null || stat -c "%s" "$file" 2>/dev/null || echo "0")

    if [ "$size" -gt 0 ]; then
        # Check for UPS shutdown before hashing
        if [ -f "/tmp/ups_emergency_shutdown" ]; then
            exit 130
        fi

        # Hash the file
        local hash_output=$($hash_cmd "$file" 2>/dev/null)
        local hash_exit=$?

        if [ $hash_exit -eq 0 ]; then
            local hash=$(echo "$hash_output" | awk '{print $1}')

            # Atomic write: Use flock to ensure only one process writes at a time
            # Write to manifest FIRST, then state file, then bytes tracking
            (
                flock -x 200
                echo "$size,$hash,$file" >> "$manifest_file"
                echo "$file" >> "$state_file"
                echo "$size" >> "${state_file}.bytes"
            ) 200>"${manifest_file}.lock"

            # Update status file for progress display (unique per worker)
            # Use BASHPID (not $$) to get actual worker PID in subshell
            echo "$size $file" > "/tmp/hash_current_${drive_label}_${BASHPID}"
        fi
    fi
}

# Export the function so xargs subshells can use it
export -f hash_single_file
export -f check_ups_shutdown

# Function to hash a single drive with resume support (PARALLEL VERSION)
hash_drive() {
    local drive_path="$1"
    local manifest_file="$2"
    local state_file="$3"
    local drive_label="$4"
    local total_files_var="$5"
    local hash_cmd="$6"
    local algorithm="$7"
    local parallelism="$8"
    local status_file="${state_file}.current"

    # Check for UPS shutdown before starting
    check_ups_shutdown

    # Create manifest header if starting fresh
    if [ ! -f "$manifest_file" ]; then
        echo "%%%% HASHDEEP-1.0" > "$manifest_file"
        echo "%%%% size,$algorithm,filename" >> "$manifest_file"
        echo "## Invoked from: $0" >> "$manifest_file"
        echo "## \$ $hash_cmd" >> "$manifest_file"
        echo "##" >> "$manifest_file"
    fi
    
    # Get list of all files (excluding macOS system files/directories)
    # Sort by parent directory to minimize seek time on HDDs
    local file_list="/tmp/files_${drive_label}_$$.txt"

    find "$drive_path" -type f \
        -not -path "*/.DocumentRevisions-V100/*" \
        -not -path "*/.Spotlight-V100/*" \
        -not -path "*/.TemporaryItems/*" \
        -not -path "*/.Trashes/*" \
        -not -path "*/.fseventsd/*" \
        -not -name ".DS_Store" \
        -not -name "._*" \
        2>/dev/null | \
        awk '{print substr($0, 1, index($0, substr($0, match($0, /[^\/]*$/))) - 1) "\t" $0}' | \
        LC_ALL=C sort | \
        cut -f2 > "$file_list"

    local total=$(wc -l < "$file_list" | xargs)
    eval "$total_files_var=$total"

    # Load already processed files
    local processed=0
    if [ -f "$state_file" ]; then
        processed=$(wc -l < "$state_file" | xargs)
        echo "[$drive_label] Resuming: $processed files already hashed, $((total - processed)) remaining"
    else
        touch "$state_file"
        echo "[$drive_label] Starting fresh: $total files to hash"
    fi

    echo "[$drive_label] Using $algorithm hashing with $parallelism parallel workers"

    # Skip already-processed files (files are sorted, so just skip first N lines)
    # Use null-delimited format for xargs -0 (handles spaces in filenames)
    local remaining_files="/tmp/remaining_${drive_label}_$$.txt"
    if [ $processed -gt 0 ]; then
        # Use tail to skip already processed files - much faster than grep!
        tail -n +$((processed + 1)) "$file_list" | tr '\n' '\0' > "$remaining_files"
    else
        tr '\n' '\0' < "$file_list" > "$remaining_files"
    fi

    # Count null-delimited entries (not lines)
    local remaining_count=$(tr '\0' '\n' < "$remaining_files" | grep -c .)
    echo "[$drive_label] $remaining_count files remaining to hash (skipped first $processed)"

    # Write config to temp file for workers to source
    local worker_config="/tmp/hash_worker_config_${drive_label}_$$.sh"
    cat > "$worker_config" << EOF
MANIFEST_FILE="$manifest_file"
STATE_FILE="$state_file"
HASH_CMD="$hash_cmd"
DRIVE_LABEL="$drive_label"
EOF

    # Use xargs to process files in parallel
    # -0: use null delimiter (not whitespace) to handle spaces in filenames
    # -n 1: pass one file path at a time to avoid command line length limit
    # -P N: run N parallel workers
    cat "$remaining_files" | xargs -0 -n 1 -P "$parallelism" bash -c '
        # Source config file for variables
        source '"$worker_config"'
        file="$0"

        # Check for UPS shutdown
        if [ -f "/tmp/ups_emergency_shutdown" ]; then
            exit 130
        fi

        # Get file size
        size=$(stat -f "%z" "$file" 2>/dev/null || stat -c "%s" "$file" 2>/dev/null || echo "0")

        if [ "$size" -gt 0 ]; then
            # Hash the file
            hash_output=$($HASH_CMD "$file" 2>/dev/null)
            hash_exit=$?

            if [ $hash_exit -eq 0 ]; then
                hash=$(echo "$hash_output" | awk '\''{print $1}'\'')

                # Atomic write with flock
                (
                    flock -x 200
                    echo "$size,$hash,$file" >> "$MANIFEST_FILE"
                    echo "$file" >> "$STATE_FILE"
                    echo "$size" >> "${STATE_FILE}.bytes"
                ) 200>"${MANIFEST_FILE}.lock"

                # Update status file (unique per worker)
                echo "$size $file" > "/tmp/hash_current_${DRIVE_LABEL}_${BASHPID}"
            fi
        fi
    '
    rm -f "$file_list" "$remaining_files" "$worker_config"
    rm -f "$status_file"
    echo "[$drive_label] Hashing complete: $total files"
}

# Count files in parallel (simple file counting)
(find "$MOUNT_POINT" -type f \
    -not -path "*/.DocumentRevisions-V100/*" \
    -not -path "*/.Spotlight-V100/*" \
    -not -path "*/.TemporaryItems/*" \
    -not -path "*/.Trashes/*" \
    -not -path "*/.fseventsd/*" \
    -not -name ".DS_Store" \
    -not -name "._*" \
    2>/dev/null | wc -l > /tmp/source_total_$$) &
SOURCE_COUNT_PID=$!
(find "$DEST_DIR" -type f \
    -not -path "*/.DocumentRevisions-V100/*" \
    -not -path "*/.Spotlight-V100/*" \
    -not -path "*/.TemporaryItems/*" \
    -not -path "*/.Trashes/*" \
    -not -path "*/.fseventsd/*" \
    -not -name ".DS_Store" \
    -not -name "._*" \
    2>/dev/null | wc -l > /tmp/dest_total_$$) &
DEST_COUNT_PID=$!

wait $SOURCE_COUNT_PID
wait $DEST_COUNT_PID

SOURCE_TOTAL=$(cat /tmp/source_total_$$ | xargs)
DEST_TOTAL=$(cat /tmp/dest_total_$$ | xargs)
rm -f /tmp/source_total_$$ /tmp/dest_total_$$

echo "Source drive: $SOURCE_TOTAL files"
echo "Destination drive: $DEST_TOTAL files"
echo ""

# Collect file sizes for accurate progress tracking
echo "Collecting file size information for progress tracking..."
SIZES_FILE="$MANIFEST_DIR/${DRIVE_NAME}_sizes.txt"

# Check if sizes file already exists (from previous run)
if [ -f "$SIZES_FILE" ] && [ -s "$SIZES_FILE" ]; then
    echo "✅ Using existing file size information"
    USE_SIZE_PROGRESS=true
else
    echo "Generating file size information..."
    # Try macOS stat first, then GNU stat
    find "$DEST_DIR" -type f \
        -not -path "*/.DocumentRevisions-V100/*" \
        -not -path "*/.Spotlight-V100/*" \
        -not -path "*/.TemporaryItems/*" \
        -not -path "*/.Trashes/*" \
        -not -path "*/.fseventsd/*" \
        -not -name ".DS_Store" \
        -not -name "._*" \
        -exec stat -f "%z %N" {} \; 2>/dev/null > "$SIZES_FILE" || \
    find "$DEST_DIR" -type f \
        -not -path "*/.DocumentRevisions-V100/*" \
        -not -path "*/.Spotlight-V100/*" \
        -not -path "*/.TemporaryItems/*" \
        -not -path "*/.Trashes/*" \
        -not -path "*/.fseventsd/*" \
        -not -name ".DS_Store" \
        -not -name "._*" \
        -exec stat -c "%s %n" {} \; 2>/dev/null > "$SIZES_FILE"
    
    if [ -f "$SIZES_FILE" ] && [ -s "$SIZES_FILE" ]; then
        echo "✅ File size information collected"
        USE_SIZE_PROGRESS=true
    else
        echo "⚠️  Could not generate file size information, using file count progress"
        USE_SIZE_PROGRESS=false
    fi
fi

# Calculate total size for progress tracking
TOTAL_SIZE=0
if [ "$USE_SIZE_PROGRESS" = true ] && [ -f "$SIZES_FILE" ]; then
    TOTAL_SIZE=$(awk '{sum += $1} END {print sum+0}' "$SIZES_FILE" 2>/dev/null || echo "0")
    if [ "$TOTAL_SIZE" -gt 0 ]; then
        echo "Total data size: $((TOTAL_SIZE / 1024 / 1024 / 1024)) GB"
    fi
fi

echo ""

# Check if we're resuming from a previous run
RESUMING=false
if [ -f "$SOURCE_STATE" ] && [ -s "$SOURCE_STATE" ]; then
    SOURCE_ALREADY_HASHED=$(wc -l < "$SOURCE_STATE" | xargs)
    if [ "$SOURCE_ALREADY_HASHED" -gt 0 ]; then
        RESUMING=true
        echo "🔄 RESUMING: Found $SOURCE_ALREADY_HASHED/$SOURCE_TOTAL files already hashed on source"
    fi
fi

if [ -f "$DEST_STATE" ] && [ -s "$DEST_STATE" ]; then
    DEST_ALREADY_HASHED=$(wc -l < "$DEST_STATE" | xargs)
    if [ "$DEST_ALREADY_HASHED" -gt 0 ]; then
        RESUMING=true
        echo "🔄 RESUMING: Found $DEST_ALREADY_HASHED/$DEST_TOTAL files already hashed on destination"
    fi
fi

if [ "$RESUMING" = true ]; then
    echo ""
    echo "✅ Resuming from previous run - skipping already-hashed files"
    echo ""
fi

echo "Hashing BOTH drives in parallel..."
echo "This will take approximately 11-15 hours (limited by slower drive)..."
echo "✅ RESUMABLE: You can stop (Ctrl+C) and restart anytime!"
echo "Started: $(date)"
echo ""

# Start UPS monitoring
start_ups_monitor

# Set up cleanup trap to include UPS monitor
cleanup() {
    echo ""
    echo "⚠️  Interrupt received! Stopping hashing processes..."
    echo "Progress has been saved and can be resumed."

    # Stop UPS monitoring
    stop_ups_monitor

    # Kill all hash processes by name (catches xargs workers)
    pkill -TERM sha256sum 2>/dev/null || true
    pkill -TERM b2sum 2>/dev/null || true
    pkill -TERM xargs 2>/dev/null || true

    # Kill entire process groups (including all child processes)
    kill -TERM -$SOURCE_PID 2>/dev/null || true
    kill -TERM -$DEST_PID 2>/dev/null || true

    # Wait a moment for graceful shutdown
    sleep 2

    # Force kill if still running
    pkill -KILL sha256sum 2>/dev/null || true
    pkill -KILL b2sum 2>/dev/null || true
    pkill -KILL xargs 2>/dev/null || true
    kill -KILL -$SOURCE_PID 2>/dev/null || true
    kill -KILL -$DEST_PID 2>/dev/null || true

    echo ""
    echo "✅ Processes stopped. Progress saved."
    echo "   Run the same command again to resume."
    exit 130
}

# Detect hash algorithms from existing manifests (or use BLAKE2 for new)
SOURCE_ALGORITHM=$(detect_hash_algorithm "$SOURCE_MANIFEST")
DEST_ALGORITHM=$(detect_hash_algorithm "$DEST_MANIFEST")

echo "Source algorithm: $SOURCE_ALGORITHM"
echo "Destination algorithm: $DEST_ALGORITHM"

# Get hash commands
SOURCE_HASH_CMD=$(get_hash_command "$SOURCE_ALGORITHM")
DEST_HASH_CMD=$(get_hash_command "$DEST_ALGORITHM")

# Detect drive types for optimal parallelism
SOURCE_DRIVE_TYPE=$(detect_drive_type "$SOURCE_DISK")
DEST_DRIVE_TYPE=$(detect_drive_type "$(df "$DEST_DIR" | tail -1 | awk '{print $1}')")

echo "Source drive type: $SOURCE_DRIVE_TYPE"
echo "Destination drive type: $DEST_DRIVE_TYPE"

# Get optimal parallelism
SOURCE_PARALLELISM=$(get_optimal_parallelism "$SOURCE_DRIVE_TYPE")
DEST_PARALLELISM=$(get_optimal_parallelism "$DEST_DRIVE_TYPE")

echo "Source parallelism: $SOURCE_PARALLELISM workers"
echo "Destination parallelism: $DEST_PARALLELISM workers"
echo ""

# Set trap for Ctrl+C and SIGTERM
trap cleanup INT TERM

# Launch both hashing processes in background
(
    hash_drive "$MOUNT_POINT" "$SOURCE_MANIFEST" "$SOURCE_STATE" "SOURCE" "SOURCE_TOTAL" "$SOURCE_HASH_CMD" "$SOURCE_ALGORITHM" "$SOURCE_PARALLELISM"
    echo $? > /tmp/source_hash_exit_$$
    echo "Source hashing completed: $(date)" > "$SOURCE_LOG"
) &
SOURCE_PID=$!

(
    hash_drive "$DEST_DIR" "$DEST_MANIFEST" "$DEST_STATE" "DEST" "DEST_TOTAL" "$DEST_HASH_CMD" "$DEST_ALGORITHM" "$DEST_PARALLELISM"
    echo $? > /tmp/dest_hash_exit_$$
    echo "Destination hashing completed: $(date)" > "$DEST_LOG"
) &
DEST_PID=$!

echo "Both hashing processes started!"
echo "Press Ctrl+C to stop - progress will be saved!"
echo ""

# Signal handler to cleanly stop both processes
cleanup() {
    echo ""
    echo "⚠️  Interrupt received! Stopping hashing processes..."
    echo "Progress has been saved and can be resumed."
    
    # Kill entire process groups (including all child processes)
    # Use negative PID to kill process group
    kill -- -$SOURCE_PID 2>/dev/null
    kill -- -$DEST_PID 2>/dev/null
    
    # Also kill by name in case process groups don't work
    pkill -P $SOURCE_PID 2>/dev/null
    pkill -P $DEST_PID 2>/dev/null
    
    # Final kill of main processes
    kill $SOURCE_PID 2>/dev/null
    kill $DEST_PID 2>/dev/null
    
    # Wait for them to finish
    wait $SOURCE_PID 2>/dev/null
    wait $DEST_PID 2>/dev/null
    
    # Clean up temp files
    rm -f /tmp/source_hash_exit_$$ /tmp/dest_hash_exit_$$
    
    # Clean up status files
    rm -f "${SOURCE_STATE}.current" "${DEST_STATE}.current" 2>/dev/null
    
    echo "✅ Stopped cleanly. Run the same command to resume."
    exit 130
}

# Trap Ctrl+C (SIGINT) and SIGTERM
trap cleanup SIGINT SIGTERM

# Load size information if available
SIZES_FILE="$MANIFEST_DIR/${DRIVE_NAME}_sizes.txt"

# Progress monitor function
monitor_progress() {
    local start_time=$(date +%s)

    # Capture initial state for this session (to calculate speed accurately)
    local initial_source_done=$(wc -l < "$SOURCE_STATE" 2>/dev/null | xargs || echo "0")
    local initial_dest_done=$(wc -l < "$DEST_STATE" 2>/dev/null | xargs || echo "0")

    # Track bytes for speed calculation (rolling average)
    # Initialize from existing .bytes files if resuming
    local last_source_bytes=0
    local last_dest_bytes=0
    if [ -f "${SOURCE_STATE}.bytes" ]; then
        last_source_bytes=$(awk '{sum+=$1} END{print sum+0}' "${SOURCE_STATE}.bytes" 2>/dev/null)
        last_source_bytes=${last_source_bytes:-0}
    fi
    if [ -f "${DEST_STATE}.bytes" ]; then
        last_dest_bytes=$(awk '{sum+=$1} END{print sum+0}' "${DEST_STATE}.bytes" 2>/dev/null)
        last_dest_bytes=${last_dest_bytes:-0}
    fi

    local last_check_time=$start_time
    local source_speed_samples=()
    local dest_speed_samples=()
    
    while kill -0 $SOURCE_PID 2>/dev/null || kill -0 $DEST_PID 2>/dev/null; do
        # Count processed files from state files
        local source_done=$(wc -l < "$SOURCE_STATE" 2>/dev/null | xargs || echo "0")
        local dest_done=$(wc -l < "$DEST_STATE" 2>/dev/null | xargs || echo "0")
        
        # Debug: Show process status
        local source_status="stopped"
        local dest_status="stopped"
        if kill -0 $SOURCE_PID 2>/dev/null; then
            source_status="running"
        fi
        if kill -0 $DEST_PID 2>/dev/null; then
            dest_status="running"
        fi
        
        # Calculate percentages based on size or count
        local source_pct=0
        local dest_pct=0
        
        if [ "$USE_SIZE_PROGRESS" = true ]; then
            # Size-based progress using fast awk lookup
            local source_size=0
            local dest_size=0
            
            # Calculate total size of processed files
            # awk: Load state file paths into array, then sum sizes for matching paths
            # Sizes file format: "size filepath" (space-separated)
            # Note: State files have absolute paths, sizes file has dest paths
            # We need to match by comparing the destination paths
            if [ -f "$SOURCE_STATE" ] && [ -s "$SOURCE_STATE" ]; then
                # For source: extract relative paths by removing mount point prefix, then match against dest paths in sizes file
                source_size=$(awk -v mount="$MOUNT_POINT" -v dest="$DEST_DIR" 'NR==FNR{gsub(mount"/",""); files[$0]=1; next} {size=$1; $1=""; filepath=substr($0,2); gsub(dest"/","",filepath); if(filepath in files) sum+=size} END{print sum+0}' "$SOURCE_STATE" "$SIZES_FILE" 2>/dev/null)
                source_size=${source_size:-0}  # Default to 0 if empty
            fi
            if [ -f "$DEST_STATE" ] && [ -s "$DEST_STATE" ]; then
                # For dest: extract relative paths by removing dest dir prefix
                dest_size=$(awk -v dest="$DEST_DIR" 'NR==FNR{gsub(dest"/",""); files[$0]=1; next} {size=$1; $1=""; filepath=substr($0,2); gsub(dest"/","",filepath); if(filepath in files) sum+=size} END{print sum+0}' "$DEST_STATE" "$SIZES_FILE" 2>/dev/null)
                dest_size=${dest_size:-0}  # Default to 0 if empty
            fi
            
            if [ $TOTAL_SIZE -gt 0 ] && [ $source_size -gt 0 ]; then
                source_pct=$((source_size * 100 / TOTAL_SIZE))
            fi
            if [ $TOTAL_SIZE -gt 0 ] && [ $dest_size -gt 0 ]; then
                dest_pct=$((dest_size * 100 / TOTAL_SIZE))
            fi
        fi
        
        # Always calculate file-count based progress as fallback
        # Use it if size-based failed (pct still 0) or if USE_SIZE_PROGRESS is false
        if [ $source_pct -eq 0 ] && [ $SOURCE_TOTAL -gt 0 ] && [ $source_done -gt 0 ]; then
            source_pct=$((source_done * 100 / SOURCE_TOTAL))
        fi
        if [ $dest_pct -eq 0 ] && [ $DEST_TOTAL -gt 0 ] && [ $dest_done -gt 0 ]; then
            dest_pct=$((dest_done * 100 / DEST_TOTAL))
        fi
        
        # Compare hashes of files processed on both sides
        local matches=0
        local mismatches=0
        local pending=0
        
        if [ -f "$SOURCE_MANIFEST" ] && [ -f "$DEST_MANIFEST" ]; then
            # Extract ONLY hashes from both manifests (format: size,hash,path)
            # Sort and deduplicate to handle any duplicate manifest entries
            awk -F',' '/^[0-9]/ {print $2}' "$SOURCE_MANIFEST" | sort -u > /tmp/source_hashes_$$.txt 2>/dev/null
            awk -F',' '/^[0-9]/ {print $2}' "$DEST_MANIFEST" | sort -u > /tmp/dest_hashes_$$.txt 2>/dev/null
            
            # Count matches (same hash exists in both)
            matches=$(comm -12 /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt 2>/dev/null | wc -l | xargs || echo "0")
            
            # Count source-only (not yet in dest)
            local source_only=$(comm -23 /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt 2>/dev/null | wc -l | xargs || echo "0")
            
            # Count dest-only (not in source)
            local dest_only=$(comm -13 /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt 2>/dev/null | wc -l | xargs || echo "0")
            
            # Pending = files hashed on one side but not the other
            pending=$((source_only + dest_only))
            
            rm -f /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt 2>/dev/null
        fi
        
        # Check if processes are still running
        local source_status="⏳"
        local dest_status="⏳"
        if ! kill -0 $SOURCE_PID 2>/dev/null; then
            source_status="✅"
            source_pct=100
            source_done=$SOURCE_TOTAL
        fi
        if ! kill -0 $DEST_PID 2>/dev/null; then
            dest_status="✅"
            dest_pct=100
            dest_done=$DEST_TOTAL
        fi
        
        # Calculate elapsed time
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        local hours=$((elapsed / 3600))
        local minutes=$(((elapsed % 3600) / 60))
        local seconds=$((elapsed % 60))
        
        # Calculate instantaneous speed (bytes processed in last interval)
        local time_since_last=$((now - last_check_time))

        # Only calculate speed if enough time passed (every 5 seconds)
        if [ $time_since_last -ge 5 ]; then
            # Get current byte counts from .bytes tracking files (FAST - just sum numbers)
            local source_current_bytes=0
            local dest_current_bytes=0

            if [ -f "${SOURCE_STATE}.bytes" ]; then
                # Fast: just sum all the file sizes (one number per line)
                source_current_bytes=$(awk '{sum+=$1} END{print sum+0}' "${SOURCE_STATE}.bytes" 2>/dev/null)
                source_current_bytes=${source_current_bytes:-0}
            fi

            if [ -f "${DEST_STATE}.bytes" ]; then
                # Fast: just sum all the file sizes
                dest_current_bytes=$(awk '{sum+=$1} END{print sum+0}' "${DEST_STATE}.bytes" 2>/dev/null)
                dest_current_bytes=${dest_current_bytes:-0}
            fi

            # Calculate speed from byte delta
            if [ $last_source_bytes -gt 0 ]; then
                local source_bytes_delta=$((source_current_bytes - last_source_bytes))
                if [ $source_bytes_delta -gt 0 ]; then
                    local source_bps=$((source_bytes_delta / time_since_last))
                    source_speed_samples+=($source_bps)
                fi
            fi

            if [ $last_dest_bytes -gt 0 ]; then
                local dest_bytes_delta=$((dest_current_bytes - last_dest_bytes))
                if [ $dest_bytes_delta -gt 0 ]; then
                    local dest_bps=$((dest_bytes_delta / time_since_last))
                    dest_speed_samples+=($dest_bps)
                fi
            fi

            # Update for next iteration
            last_source_bytes=$source_current_bytes
            last_dest_bytes=$dest_current_bytes
            last_check_time=$now
        fi

        # Calculate per-drive speeds and ETAs
        local source_speed="calculating..."
        local dest_speed="calculating..."
        local source_eta="calculating..."
        local dest_eta="calculating..."

        # Use rolling average of last samples for smooth speed display
        if [ ${#source_speed_samples[@]} -gt 0 ]; then
            local source_avg=0
            for speed in "${source_speed_samples[@]}"; do
                source_avg=$((source_avg + speed))
            done
            source_avg=$((source_avg / ${#source_speed_samples[@]}))
            source_speed="$(numfmt --to=si --suffix=B/s $source_avg 2>/dev/null || echo "${source_avg}B/s")"

            # Calculate ETA
            if [ $source_avg -gt 0 ] && [ $TOTAL_SIZE -gt 0 ]; then
                local source_remaining=$((TOTAL_SIZE - (source_done * TOTAL_SIZE / SOURCE_TOTAL)))
                local source_eta_sec=$((source_remaining / source_avg))
                local source_eta_hrs=$((source_eta_sec / 3600))
                local source_eta_min=$(((source_eta_sec % 3600) / 60))
                source_eta="${source_eta_hrs}h ${source_eta_min}m"
            fi
        fi

        if [ ${#dest_speed_samples[@]} -gt 0 ]; then
            local dest_avg=0
            for speed in "${dest_speed_samples[@]}"; do
                dest_avg=$((dest_avg + speed))
            done
            dest_avg=$((dest_avg / ${#dest_speed_samples[@]}))
            dest_speed="$(numfmt --to=si --suffix=B/s $dest_avg 2>/dev/null || echo "${dest_avg}B/s")"

            # Calculate ETA
            if [ $dest_avg -gt 0 ] && [ $TOTAL_SIZE -gt 0 ]; then
                local dest_remaining=$((TOTAL_SIZE - (dest_done * TOTAL_SIZE / DEST_TOTAL)))
                local dest_eta_sec=$((dest_remaining / dest_avg))
                local dest_eta_hrs=$((dest_eta_sec / 3600))
                local dest_eta_min=$(((dest_eta_sec % 3600) / 60))
                dest_eta="${dest_eta_hrs}h ${dest_eta_min}m"
            fi
        fi

        # OLD SLOW CODE - DISABLED
        if false; then
        # Wait at least 30 seconds and need some progress before showing estimates
        if [ $elapsed -gt 30 ]; then
            if false; then  # Disabled: size-based is slow with parallel workers
                # Size-based speed and ETA for SOURCE
                # Use awk for fast lookup instead of slow grep
                if [ $source_done -gt 5 ] && [ $source_pct -gt 0 ] && [ $source_pct -lt 100 ]; then
                    local source_bytes_done=$(awk -v mount="$MOUNT_POINT" -v dest="$DEST_DIR" 'NR==FNR{gsub(mount"/",""); files[$0]=1; next} {size=$1; $1=""; filepath=substr($0,2); gsub(dest"/","",filepath); if(filepath in files) sum+=size} END{print sum+0}' "$SOURCE_STATE" "$SIZES_FILE" 2>/dev/null)
                    source_bytes_done=${source_bytes_done:-0}
                    
                    # Calculate speed based on progress THIS SESSION only
                    local source_bytes_this_session=$((source_bytes_done - initial_source_size))
                    if [ $source_bytes_this_session -gt 0 ] && [ $elapsed -gt 0 ]; then
                        local source_speed_bps=$((source_bytes_this_session / elapsed))
                        source_speed="$(numfmt --to=si --suffix=B/s $source_speed_bps 2>/dev/null || echo "${source_speed_bps} B/s")"
                        
                        if [ $source_speed_bps -gt 0 ]; then
                            local source_remaining=$((TOTAL_SIZE - source_bytes_done))
                            local source_eta_sec=$((source_remaining / source_speed_bps))
                            local source_eta_hrs=$((source_eta_sec / 3600))
                            local source_eta_min=$(((source_eta_sec % 3600) / 60))
                            source_eta="${source_eta_hrs}h ${source_eta_min}m"
                        fi
                    fi
                fi
                
                # Size-based speed and ETA for DESTINATION
                if [ $dest_done -gt 5 ] && [ $dest_pct -gt 0 ] && [ $dest_pct -lt 100 ]; then
                    local dest_bytes_done=$(awk -v dest="$DEST_DIR" 'NR==FNR{gsub(dest"/",""); files[$0]=1; next} {size=$1; $1=""; filepath=substr($0,2); gsub(dest"/","",filepath); if(filepath in files) sum+=size} END{print sum+0}' "$DEST_STATE" "$SIZES_FILE" 2>/dev/null)
                    dest_bytes_done=${dest_bytes_done:-0}
                    
                    # Calculate speed based on progress THIS SESSION only
                    local dest_bytes_this_session=$((dest_bytes_done - initial_dest_size))
                    if [ $dest_bytes_this_session -gt 0 ] && [ $elapsed -gt 0 ]; then
                        local dest_speed_bps=$((dest_bytes_this_session / elapsed))
                        dest_speed="$(numfmt --to=si --suffix=B/s $dest_speed_bps 2>/dev/null || echo "${dest_speed_bps} B/s")"
                        
                        if [ $dest_speed_bps -gt 0 ]; then
                            local dest_remaining=$((TOTAL_SIZE - dest_bytes_done))
                            local dest_eta_sec=$((dest_remaining / dest_speed_bps))
                            local dest_eta_hrs=$((dest_eta_sec / 3600))
                            local dest_eta_min=$(((dest_eta_sec % 3600) / 60))
                            dest_eta="${dest_eta_hrs}h ${dest_eta_min}m"
                        fi
                    fi
                fi
            else
                # File-count based speed and ETA (fallback)
                # Calculate based on progress THIS SESSION only
                local source_files_this_session=$((source_done - initial_source_done))
                if [ $source_files_this_session -gt 10 ] && [ $source_pct -gt 0 ] && [ $source_pct -lt 100 ] && [ $elapsed -gt 0 ]; then
                    local source_rate=$((source_files_this_session / elapsed))
                    source_speed="${source_rate} files/s"
                    
                    if [ $source_rate -gt 0 ]; then
                        local source_remaining=$((SOURCE_TOTAL - source_done))
                        local source_eta_sec=$((source_remaining / source_rate))
                        local source_eta_hrs=$((source_eta_sec / 3600))
                        local source_eta_min=$(((source_eta_sec % 3600) / 60))
                        source_eta="${source_eta_hrs}h ${source_eta_min}m"
                    fi
                fi
                
                local dest_files_this_session=$((dest_done - initial_dest_done))
                if [ $dest_files_this_session -gt 10 ] && [ $dest_pct -gt 0 ] && [ $dest_pct -lt 100 ] && [ $elapsed -gt 0 ]; then
                    local dest_rate=$((dest_files_this_session / elapsed))
                    dest_speed="${dest_rate} files/s"
                    
                    if [ $dest_rate -gt 0 ]; then
                        local dest_remaining=$((DEST_TOTAL - dest_done))
                        local dest_eta_sec=$((dest_remaining / dest_rate))
                        local dest_eta_hrs=$((dest_eta_sec / 3600))
                        local dest_eta_min=$(((dest_eta_sec % 3600) / 60))
                        dest_eta="${dest_eta_hrs}h ${dest_eta_min}m"
                    fi
                fi
            fi
        fi
        fi  # End of if false block

        # Clear screen and show progress
        clear
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║              HASHING PROGRESS - BOTH DRIVES                    ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Started: $(date -r $start_time '+%Y-%m-%d %H:%M:%S')"
        echo "Elapsed: ${hours}h ${minutes}m ${seconds}s"
        echo ""
        echo "┌─────────────────────────────────────────────────────────────┐"
        echo "│ SOURCE DRIVE (Old Drive - Read-Only)                        │"
        echo "└─────────────────────────────────────────────────────────────┘"
        printf "Status: %s  [" "$source_status"
        
        # Progress bar for source (50 chars wide)
        local source_bar_width=$((source_pct / 2))
        for ((i=0; i<50; i++)); do
            if [ $i -lt $source_bar_width ]; then
                printf "█"
            else
                printf "░"
            fi
        done
        printf "] %3d%%\n" "$source_pct"
        printf "Files: %'d / %'d\n" "$source_done" "$SOURCE_TOTAL"
        
        # Show size processed if available
        if [ "$USE_SIZE_PROGRESS" = true ] && [ $elapsed -gt 30 ]; then
            local source_bytes=$(awk -v mount="$MOUNT_POINT" -v dest="$DEST_DIR" 'NR==FNR{gsub(mount"/",""); files[$0]=1; next} {size=$1; $1=""; filepath=substr($0,2); gsub(dest"/","",filepath); if(filepath in files) sum+=size} END{print sum+0}' "$SOURCE_STATE" "$SIZES_FILE" 2>/dev/null)
            source_bytes=${source_bytes:-0}
            if [ $source_bytes -gt 0 ] && [ $TOTAL_SIZE -gt 0 ]; then
                printf "Size:  %s / %s\n" "$(numfmt --to=si --suffix=B $source_bytes 2>/dev/null || echo "$source_bytes B")" "$(numfmt --to=si --suffix=B $TOTAL_SIZE 2>/dev/null || echo "$TOTAL_SIZE B")"
            fi
        fi
        
        # Only show speed/ETA if still processing
        if [ $source_pct -lt 100 ]; then
            printf "Speed: %s\n" "$source_speed"
            printf "ETA:   %s\n" "$source_eta"
        else
            printf "Status: Complete\n"
        fi

        # Show currently hashing files (all parallel workers)
        local worker_files=$(find /tmp -name "hash_current_SOURCE_*" -type f 2>/dev/null | head -5)
        if [ -n "$worker_files" ]; then
            local worker_count=0
            while IFS= read -r worker_file; do
                if [ -f "$worker_file" ]; then
                    local current_info=$(cat "$worker_file" 2>/dev/null)
                    if [ -n "$current_info" ]; then
                        local current_file=$(echo "$current_info" | cut -d' ' -f2-)
                        local rel_path="${current_file#$MOUNT_POINT/}"
                        local rel_path_short=$(basename "$(dirname "$rel_path")")/$(basename "$rel_path")
                        [ $worker_count -eq 0 ] && printf "Now:   " || printf "       "
                        printf "%s\n" "$rel_path_short"
                        worker_count=$((worker_count + 1))
                    fi
                fi
            done <<< "$worker_files"
        fi
        echo ""
        
        echo "┌─────────────────────────────────────────────────────────────┐"
        echo "│ DESTINATION DRIVE (New Exos - Archive)                      │"
        echo "└─────────────────────────────────────────────────────────────┘"
        printf "Status: %s  [" "$dest_status"
        
        # Progress bar for destination (50 chars wide)
        local dest_bar_width=$((dest_pct / 2))
        for ((i=0; i<50; i++)); do
            if [ $i -lt $dest_bar_width ]; then
                printf "█"
            else
                printf "░"
            fi
        done
        printf "] %3d%%\n" "$dest_pct"
        printf "Files: %'d / %'d\n" "$dest_done" "$DEST_TOTAL"
        
        # Show size processed if available
        if [ "$USE_SIZE_PROGRESS" = true ] && [ $elapsed -gt 30 ]; then
            local dest_bytes=$(awk -v dest="$DEST_DIR" 'NR==FNR{gsub(dest"/",""); files[$0]=1; next} {size=$1; $1=""; filepath=substr($0,2); gsub(dest"/","",filepath); if(filepath in files) sum+=size} END{print sum+0}' "$DEST_STATE" "$SIZES_FILE" 2>/dev/null)
            dest_bytes=${dest_bytes:-0}
            if [ $dest_bytes -gt 0 ] && [ $TOTAL_SIZE -gt 0 ]; then
                printf "Size:  %s / %s\n" "$(numfmt --to=si --suffix=B $dest_bytes 2>/dev/null || echo "$dest_bytes B")" "$(numfmt --to=si --suffix=B $TOTAL_SIZE 2>/dev/null || echo "$TOTAL_SIZE B")"
            fi
        fi
        
        # Only show speed/ETA if still processing
        if [ $dest_pct -lt 100 ]; then
            printf "Speed: %s\n" "$dest_speed"
            printf "ETA:   %s\n" "$dest_eta"
        else
            printf "Status: Complete\n"
        fi

        # Show currently hashing files (all parallel workers)
        local worker_files=$(find /tmp -name "hash_current_DEST_*" -type f 2>/dev/null | head -5)
        if [ -n "$worker_files" ]; then
            local worker_count=0
            while IFS= read -r worker_file; do
                if [ -f "$worker_file" ]; then
                    local current_info=$(cat "$worker_file" 2>/dev/null)
                    if [ -n "$current_info" ]; then
                        local current_file=$(echo "$current_info" | cut -d' ' -f2-)
                        local rel_path="${current_file#$DEST_DIR/}"
                        local rel_path_short=$(basename "$(dirname "$rel_path")")/$(basename "$rel_path")
                        [ $worker_count -eq 0 ] && printf "Now:   " || printf "       "
                        printf "%s\n" "$rel_path_short"
                        worker_count=$((worker_count + 1))
                    fi
                fi
            done <<< "$worker_files"
        fi
        echo ""
        echo "┌─────────────────────────────────────────────────────────────┐"
        echo "│ HASH COMPARISON (Real-time)                                 │"
        echo "└─────────────────────────────────────────────────────────────┘"
        printf "✅ Matching hashes: %'d files\n" "$matches"
        printf "⏳ Pending comparison: %'d files\n" "$pending"
        if [ $matches -gt 0 ]; then
            local match_pct=$((matches * 100 / (matches + pending)))
            printf "Match rate: %d%%\n" "$match_pct"
        fi
        echo ""
        echo "─────────────────────────────────────────────────────────────────"
        echo "✅ RESUMABLE: Press Ctrl+C to stop - progress is saved!"
        echo ""
        echo "Monitor in separate terminals:"
        echo "  tail -f $SOURCE_MANIFEST"
        echo "  tail -f $DEST_MANIFEST"
        
        # Update every 5 seconds
        sleep 5
    done
    
    # Final update
    clear
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║              HASHING COMPLETE - BOTH DRIVES                    ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    local total_time=$(($(date +%s) - start_time))
    local total_hours=$((total_time / 3600))
    local total_mins=$(((total_time % 3600) / 60))
    echo "✅ Source drive: $SOURCE_TOTAL files hashed"
    echo "✅ Destination drive: $DEST_TOTAL files hashed"
    echo "⏱️  Total time: ${total_hours}h ${total_mins}m"
    echo ""
}

# Run progress monitor
monitor_progress

# Wait for both processes to ensure clean exit
wait $SOURCE_PID 2>/dev/null
wait $DEST_PID 2>/dev/null

# Get exit codes
SOURCE_HASH_EXIT=$(cat /tmp/source_hash_exit_$$ 2>/dev/null || echo "1")
DEST_HASH_EXIT=$(cat /tmp/dest_hash_exit_$$ 2>/dev/null || echo "1")
rm -f /tmp/source_hash_exit_$$ /tmp/dest_hash_exit_$$

# Stop UPS monitoring
stop_ups_monitor

echo "Both hashing processes completed: $(date)"
echo ""

if [ $SOURCE_HASH_EXIT -ne 0 ]; then
    echo "⚠️  Warning: Source hashing had errors (exit code: $SOURCE_HASH_EXIT)"
fi

if [ $DEST_HASH_EXIT -ne 0 ]; then
    echo "⚠️  Warning: Destination hashing had errors (exit code: $DEST_HASH_EXIT)"
fi

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║              STEP 2 COMPLETE                   ║"
echo "╚════════════════════════════════════════════════╝"
echo "Source manifest: $SOURCE_MANIFEST"
echo "Destination manifest: $DEST_MANIFEST"
echo ""
echo "════════════════════════════════════════════════"
echo "Next step: Compare manifests and verify integrity"
echo "Run: ./step3-verify.sh \"$DRIVE_NAME\" $DEST_BASE"
echo "════════════════════════════════════════════════"

if [ $SOURCE_HASH_EXIT -eq 0 ] && [ $DEST_HASH_EXIT -eq 0 ]; then
    exit 0
else
    exit 1
fi
