#!/bin/bash
# STEP 2: HASH BOTH DRIVES IN PARALLEL
# Creates SHA256 hash manifests for source and destination

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <source_disk> <drive_name> <destination_path>"
    echo "Example: $0 /dev/disk4s2 \"Project_2015\" /Volumes/Exos24TB"
    echo ""
    echo "This script creates hash manifests for both source and destination drives"
    echo "Note: Ensure source disk is mounted (read-only recommended)"
    exit 1
fi

SOURCE_DISK=$1
DRIVE_NAME=$2
DEST_BASE=$3

DEST_DIR="$DEST_BASE/video_rushes/$DRIVE_NAME"
LOG_DIR="$DEST_BASE/_logs"
MANIFEST_DIR="$DEST_BASE/_manifests"

# Check for hashdeep
if ! command -v hashdeep &> /dev/null; then
    echo "ERROR: hashdeep not found. Install with: brew install md5deep"
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
echo "║      STEP 2: HASH VERIFICATION SETUP          ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
echo "Source: $MOUNT_POINT"
echo "Destination: $DEST_DIR"
echo ""

SOURCE_MANIFEST="$MANIFEST_DIR/${DRIVE_NAME}_source_manifest.txt"
DEST_MANIFEST="$MANIFEST_DIR/${DRIVE_NAME}_manifest.txt"
SOURCE_LOG="$LOG_DIR/${DRIVE_NAME}_source_hash.log"
DEST_LOG="$LOG_DIR/${DRIVE_NAME}_dest_hash.log"

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

echo "Hashing BOTH drives in parallel..."
echo "This will take approximately 11-15 hours (limited by slower drive)..."
echo "Started: $(date)"
echo ""

# Launch both hashdeep processes in background
(
    hashdeep -r -l -c sha256 "$MOUNT_POINT" > "$SOURCE_MANIFEST" 2>&1
    echo $? > /tmp/source_hash_exit_$$
    echo "Source hashing completed: $(date)" > "$SOURCE_LOG"
) &
SOURCE_PID=$!

(
    hashdeep -r -l -c sha256 "$DEST_DIR" > "$DEST_MANIFEST" 2>&1
    echo $? > /tmp/dest_hash_exit_$$
    echo "Destination hashing completed: $(date)" > "$DEST_LOG"
) &
DEST_PID=$!

echo "Both hashing processes started!"
echo ""

# Progress monitor function
monitor_progress() {
    local start_time=$(date +%s)
    
    while kill -0 $SOURCE_PID 2>/dev/null || kill -0 $DEST_PID 2>/dev/null; do
        # Count processed files (skip header lines)
        local source_done=$(grep -c "^[0-9]" "$SOURCE_MANIFEST" 2>/dev/null || echo "0")
        local dest_done=$(grep -c "^[0-9]" "$DEST_MANIFEST" 2>/dev/null || echo "0")
        
        # Calculate percentages
        local source_pct=0
        local dest_pct=0
        if [ $SOURCE_TOTAL -gt 0 ]; then
            source_pct=$((source_done * 100 / SOURCE_TOTAL))
        fi
        if [ $DEST_TOTAL -gt 0 ]; then
            dest_pct=$((dest_done * 100 / DEST_TOTAL))
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
        
        # Estimate time remaining (based on source, as it's usually slower)
        local eta="calculating..."
        if [ $source_done -gt 100 ] && [ $source_pct -gt 0 ] && [ $source_pct -lt 100 ]; then
            local rate=$((source_done * 100 / elapsed))  # files per 100 seconds
            if [ $rate -gt 0 ]; then
                local remaining_files=$((SOURCE_TOTAL - source_done))
                local eta_seconds=$((remaining_files * 100 / rate))
                local eta_hours=$((eta_seconds / 3600))
                local eta_mins=$(((eta_seconds % 3600) / 60))
                eta="${eta_hours}h ${eta_mins}m"
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
        echo "ETA: $eta"
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
        echo ""
        echo "─────────────────────────────────────────────────────────────────"
        echo "Press Ctrl+C to stop monitoring (hashing will continue)"
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
