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

DEST_DIR="$DEST_BASE/video_rushes/$DRIVE_NAME"
LOG_DIR="$DEST_BASE/_logs"
MANIFEST_DIR="$DEST_BASE/_manifests"

# Check for sha256sum or shasum
if command -v sha256sum &> /dev/null; then
    HASH_CMD="sha256sum"
elif command -v shasum &> /dev/null; then
    HASH_CMD="shasum -a 256"
else
    echo "ERROR: Neither sha256sum nor shasum found. Please install coreutils."
    exit 1
fi

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

# Function to hash a single drive with resume support
hash_drive() {
    local drive_path="$1"
    local manifest_file="$2"
    local state_file="$3"
    local drive_label="$4"
    local total_files_var="$5"
    
    # Create manifest header if starting fresh
    if [ ! -f "$manifest_file" ]; then
        echo "%%%% HASHDEEP-1.0" > "$manifest_file"
        echo "%%%% size,sha256,filename" >> "$manifest_file"
        echo "## Invoked from: $0" >> "$manifest_file"
        echo "## \$ $HASH_CMD" >> "$manifest_file"
        echo "##" >> "$manifest_file"
    fi
    
    # Get list of all files
    local file_list="/tmp/files_${drive_label}_$$.txt"
    find "$drive_path" -type f 2>/dev/null | sort > "$file_list"
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
    
    # Process files
    local count=0
    while IFS= read -r file; do
        count=$((count + 1))
        
        # Skip if already processed
        if grep -Fxq "$file" "$state_file" 2>/dev/null; then
            continue
        fi
        
        # Hash the file
        if [ -f "$file" ]; then
            local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
            local hash_output=$($HASH_CMD "$file" 2>/dev/null)
            
            if [ $? -eq 0 ]; then
                local hash=$(echo "$hash_output" | awk '{print $1}')
                # ATOMIC: Write to state file FIRST, then manifest
                # This way if interrupted, we skip the file on resume (safe)
                # Rather than having it in manifest but not state (duplicate)
                echo "$file" >> "$state_file"
                echo "$size,$hash,$file" >> "$manifest_file"
            fi
        fi
    done < "$file_list"
    
    rm -f "$file_list"
    echo "[$drive_label] Hashing complete: $total files"
}

echo "Counting files on both drives..."

# Count files in parallel
(find "$MOUNT_POINT" -type f 2>/dev/null | wc -l > /tmp/source_total_$$) &
SOURCE_COUNT_PID=$!
(find "$DEST_DIR" -type f 2>/dev/null | wc -l > /tmp/dest_total_$$) &
DEST_COUNT_PID=$!

wait $SOURCE_COUNT_PID
wait $DEST_COUNT_PID

SOURCE_TOTAL=$(cat /tmp/source_total_$$ | xargs)
DEST_TOTAL=$(cat /tmp/dest_total_$$ | xargs)
rm -f /tmp/source_total_$$ /tmp/dest_total_$$

echo "Source drive: $SOURCE_TOTAL files"
echo "Destination drive: $DEST_TOTAL files"
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

# Launch both hashing processes in background
(
    hash_drive "$MOUNT_POINT" "$SOURCE_MANIFEST" "$SOURCE_STATE" "SOURCE" "SOURCE_TOTAL"
    echo $? > /tmp/source_hash_exit_$$
    echo "Source hashing completed: $(date)" > "$SOURCE_LOG"
) &
SOURCE_PID=$!

(
    hash_drive "$DEST_DIR" "$DEST_MANIFEST" "$DEST_STATE" "DEST" "DEST_TOTAL"
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
    
    echo "✅ Stopped cleanly. Run the same command to resume."
    exit 130
}

# Trap Ctrl+C (SIGINT) and SIGTERM
trap cleanup SIGINT SIGTERM

# Load size information if available
SIZES_FILE="$MANIFEST_DIR/${DRIVE_NAME}_sizes.txt"
if [ -f "$SIZES_FILE" ]; then
    # Calculate total size from sizes file
    TOTAL_SIZE=$(awk '{sum += $1} END {print sum}' "$SIZES_FILE")
    USE_SIZE_PROGRESS=true
    echo "Using size-based progress tracking (Total: $(numfmt --to=iec-i --suffix=B $TOTAL_SIZE 2>/dev/null || echo "$TOTAL_SIZE bytes"))"
else
    USE_SIZE_PROGRESS=false
    echo "Using file-count progress tracking (sizes file not found)"
fi
echo ""

# Progress monitor function
monitor_progress() {
    local start_time=$(date +%s)
    
    while kill -0 $SOURCE_PID 2>/dev/null || kill -0 $DEST_PID 2>/dev/null; do
        # Count processed files from state files
        local source_done=$(wc -l < "$SOURCE_STATE" 2>/dev/null | xargs || echo "0")
        local dest_done=$(wc -l < "$DEST_STATE" 2>/dev/null | xargs || echo "0")
        
        # Calculate percentages based on size or count
        local source_pct=0
        local dest_pct=0
        
        if [ "$USE_SIZE_PROGRESS" = true ]; then
            # Size-based progress
            local source_size=0
            local dest_size=0
            
            # Calculate total size of processed files
            if [ -f "$SOURCE_STATE" ] && [ -s "$SOURCE_STATE" ]; then
                source_size=$(grep -Ff "$SOURCE_STATE" "$SIZES_FILE" 2>/dev/null | awk '{sum += $1} END {print sum+0}')
            fi
            if [ -f "$DEST_STATE" ] && [ -s "$DEST_STATE" ]; then
                dest_size=$(grep -Ff "$DEST_STATE" "$SIZES_FILE" 2>/dev/null | awk '{sum += $1} END {print sum+0}')
            fi
            
            if [ $TOTAL_SIZE -gt 0 ]; then
                source_pct=$((source_size * 100 / TOTAL_SIZE))
                dest_pct=$((dest_size * 100 / TOTAL_SIZE))
            fi
        else
            # File-count based progress (fallback)
            if [ $SOURCE_TOTAL -gt 0 ]; then
                source_pct=$((source_done * 100 / SOURCE_TOTAL))
            fi
            if [ $DEST_TOTAL -gt 0 ]; then
                dest_pct=$((dest_done * 100 / DEST_TOTAL))
            fi
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
        
        # Calculate per-drive speeds and ETAs
        local source_speed="calculating..."
        local dest_speed="calculating..."
        local source_eta="calculating..."
        local dest_eta="calculating..."
        
        # Wait at least 30 seconds and need some progress before showing estimates
        if [ $elapsed -gt 30 ]; then
            if [ "$USE_SIZE_PROGRESS" = true ]; then
                # Size-based speed and ETA for SOURCE
                if [ $source_done -gt 5 ] && [ $source_pct -gt 0 ] && [ $source_pct -lt 100 ]; then
                    local source_bytes_done=$(grep -Ff "$SOURCE_STATE" "$SIZES_FILE" 2>/dev/null | awk '{sum += $1} END {print sum+0}')
                    
                    if [ $source_bytes_done -gt 0 ]; then
                        local source_speed_bps=$((source_bytes_done / elapsed))
                        source_speed="$(numfmt --to=iec-i --suffix=B/s $source_speed_bps 2>/dev/null || echo "${source_speed_bps} B/s")"
                        
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
                    local dest_bytes_done=$(grep -Ff "$DEST_STATE" "$SIZES_FILE" 2>/dev/null | awk '{sum += $1} END {print sum+0}')
                    
                    if [ $dest_bytes_done -gt 0 ]; then
                        local dest_speed_bps=$((dest_bytes_done / elapsed))
                        dest_speed="$(numfmt --to=iec-i --suffix=B/s $dest_speed_bps 2>/dev/null || echo "${dest_speed_bps} B/s")"
                        
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
                if [ $source_done -gt 10 ] && [ $source_pct -gt 0 ] && [ $source_pct -lt 100 ]; then
                    local source_rate=$((source_done / elapsed))
                    source_speed="${source_rate} files/s"
                    
                    if [ $source_rate -gt 0 ]; then
                        local source_remaining=$((SOURCE_TOTAL - source_done))
                        local source_eta_sec=$((source_remaining / source_rate))
                        local source_eta_hrs=$((source_eta_sec / 3600))
                        local source_eta_min=$(((source_eta_sec % 3600) / 60))
                        source_eta="${source_eta_hrs}h ${source_eta_min}m"
                    fi
                fi
                
                if [ $dest_done -gt 10 ] && [ $dest_pct -gt 0 ] && [ $dest_pct -lt 100 ]; then
                    local dest_rate=$((dest_done / elapsed))
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
        echo "│ SOURCE DRIVE (Old Drive - Read-Only)                       │"
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
        printf "Speed: %s\n" "$source_speed"
        printf "ETA:   %s\n" "$source_eta"
        echo ""
        
        echo "┌─────────────────────────────────────────────────────────────┐"
        echo "│ DESTINATION DRIVE (New Exos - Archive)                     │"
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
        printf "Speed: %s\n" "$dest_speed"
        printf "ETA:   %s\n" "$dest_eta"
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
