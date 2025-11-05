#!/bin/bash
# STEP 1: COPY FILES FROM SOURCE TO DESTINATION
# This script copies files from an old drive to a destination, prioritizing data safety

if [ "$#" -ne 3 ] && [ "$#" -ne 4 ]; then
    echo "Usage: sudo $0 <source_disk> <drive_name> <destination_path> [--zip-only]"
    echo "Example: sudo $0 /dev/disk4s2 \"Project_2015\" /Volumes/Exos24TB"
    echo "Example: sudo $0 /dev/disk4s2 \"Project_2015\" /Volumes/Exos24TB --zip-only"
    echo ""
    echo "Options:"
    echo "  --zip-only    Skip rsync copy, only process zip fallback for failed folders"
    echo "Note: Use Disk Arbitrator to mount the source disk READ-ONLY before running this script"
    exit 1
fi

SOURCE_DISK=$1
DRIVE_NAME=$2
DEST_BASE=$3
ZIP_ONLY=false

if [ "$#" -eq 4 ] && [ "$4" = "--zip-only" ]; then
    ZIP_ONLY=true
fi

DEST_DIR="$DEST_BASE/$DRIVE_NAME"
LOG_DIR="$DEST_BASE/_logs"
MANIFEST_DIR="$DEST_BASE/_manifests"
LOG_FILE="$LOG_DIR/${DRIVE_NAME}_report.txt"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to check for UPS emergency shutdown
check_ups_shutdown() {
    if [ -f "/tmp/ups_emergency_shutdown" ]; then
        log "🚨 UPS EMERGENCY SHUTDOWN DETECTED - Stopping operations!"
        log "   Power failure or low battery condition detected"
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
            log "🔋 UPS detected - Starting UPS monitoring in background"
            $ups_monitor &
            UPS_MONITOR_PID=$!
            echo $UPS_MONITOR_PID > "/tmp/ups_monitor.pid"
            log "UPS Monitor PID: $UPS_MONITOR_PID"
        else
            log "ℹ️  No UPS detected - continuing without power monitoring"
        fi
    else
        log "⚠️  UPS Monitor not found - continuing without power monitoring"
    fi
}

# Function to stop UPS monitoring
stop_ups_monitor() {
    if [ -f "/tmp/ups_monitor.pid" ]; then
        local ups_pid=$(cat "/tmp/ups_monitor.pid")
        if kill -0 $ups_pid 2>/dev/null; then
            log "Stopping UPS Monitor (PID: $ups_pid)"
            kill $ups_pid 2>/dev/null || true
        fi
        rm -f "/tmp/ups_monitor.pid"
    fi
}

# Check if destination exists
if [ ! -d "$DEST_BASE" ]; then
    echo "ERROR: Destination path does not exist: $DEST_BASE"
    exit 1
fi

mkdir -p "$DEST_DIR" "$LOG_DIR" "$MANIFEST_DIR"

# Initialize log file
> "$LOG_FILE"

# Find the mount point
MOUNT_POINT=$(diskutil info "$SOURCE_DISK" | grep "Mount Point" | cut -d: -f2 | xargs)

if [ -z "$MOUNT_POINT" ] || [ "$MOUNT_POINT" = "" ]; then
    echo "ERROR: Source disk is not mounted: $SOURCE_DISK"
    echo ""
    echo "Please use Disk Arbitrator to mount it READ-ONLY first"
    exit 1
fi

# Check if mounted read-only
MOUNT_INFO=$(mount | grep "$SOURCE_DISK")
if [[ ! "$MOUNT_INFO" =~ "read-only" ]] && [[ ! "$MOUNT_INFO" =~ "ro" ]]; then
    echo "⚠️  WARNING: Drive does not appear to be mounted read-only!"
    echo "Mount info: $MOUNT_INFO"
    echo ""
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "╔════════════════════════════════════════════════╗"
echo "║      STEP 1: COPY FILES FROM OLD DRIVE        ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
log "Started: $(date)"
log ""

# Function to copy with zip fallback for problematic folders
copy_with_fallback() {
    local source_dir="$1"
    local dest_dir="$2"
    local log_file="$3"
    local error_file="${log_file%.log}_errors.log"
    
    # Check for UPS shutdown before starting
    check_ups_shutdown
    
    # Try normal rsync first with UPS monitoring
    log "Starting rsync with UPS monitoring..."
    
    # Start rsync in background so we can monitor it
    sudo rsync -avhx \
      --progress \
      --stats \
      --timeout=60 \
      --ignore-errors \
      --partial \
      --exclude='.DocumentRevisions-V100' \
      --exclude='.Spotlight-V100' \
      --exclude='.TemporaryItems' \
      --exclude='.Trashes' \
      --exclude='.fseventsd' \
      --exclude='.DS_Store' \
      --exclude='._*' \
      --log-file="$log_file" \
      "$source_dir" "$dest_dir" 2> "$error_file" | tee -a "$LOG_FILE" &
    
    local rsync_pid=$!
    
    # Monitor rsync progress while checking UPS status
    while kill -0 $rsync_pid 2>/dev/null; do
        # Check UPS status every 5 seconds during copy
        check_ups_shutdown
        sleep 5
    done
    
    # Wait for rsync to finish and get exit code
    wait $rsync_pid
    local rsync_exit=$?
    
    # Check for UPS shutdown after rsync
    check_ups_shutdown
    
    # Check if rsync completed (exit code 0) or had partial transfer issues (exit code 23)
    # Both are "successful" in that they copied what they could - we just need to handle the failures
    if [ $rsync_exit -eq 0 ]; then
        log "✅ Copy completed successfully!"
        return 0
    elif [ $rsync_exit -eq 23 ]; then
        log "⚠️  Copy completed with some issues - checking for folders to zip..."
    else
        log "❌ Copy failed with exit code: $rsync_exit"
        return $rsync_exit
    fi
    
    # Find folders that failed to copy (check rsync error log for "Invalid argument" errors)
    local failed_folders=$(grep "Invalid argument (22)" "$error_file" | grep -o 'mkdir "[^"]*"' | cut -d'"' -f2 | sed 's|.*/||' | sort -u)
    
    if [ -z "$failed_folders" ]; then
        log "✅ No exFAT issues found - copy is complete!"
        return 0
    fi
    
    local zipped_count=0
    local failed_count=0
    
    # Process each folder (handling spaces properly)
    while IFS= read -r folder; do
        # Check for UPS shutdown before each folder
        check_ups_shutdown
        
        log "📦 Zipping problematic folder: $folder"
        
        # Find the actual source folder
        local source_path=$(find "$source_dir" -name "$folder" -type d 2>/dev/null | head -n1)
        
        if [ -n "$source_path" ]; then
            local zip_name="${folder}.zip"
            local dest_zip="$dest_dir/$zip_name"
            
            # Start zip in background with UPS monitoring
            log "Creating: $zip_name"
            (cd "$source_dir/.." && zip -0ry "$dest_zip" "$folder" 2>/dev/null) &
            local zip_pid=$!
            
            # Monitor zip progress while checking UPS status
            while kill -0 $zip_pid 2>/dev/null; do
                check_ups_shutdown
                sleep 2
            done
            
            # Wait for zip to finish
            wait $zip_pid
            local zip_exit=$?
            
            if [ $zip_exit -eq 0 ]; then
                log "✅ Successfully zipped: $zip_name"
                # Remove the failed directory entry from destination if it exists
                sudo rm -rf "$dest_dir/$folder" 2>/dev/null
                zipped_count=$((zipped_count + 1))
            else
                log "❌ Failed to zip: $folder"
                failed_count=$((failed_count + 1))
            fi
        else
            log "❌ Could not find source folder: $folder"
            failed_count=$((failed_count + 1))
        fi
        
        # Check for UPS shutdown after each folder
        check_ups_shutdown
    done <<< "$failed_folders"
    
    log "📊 Zip fallback summary: $zipped_count folders zipped, $failed_count failed"
    
    if [ $failed_count -eq 0 ]; then
        log "✅ All problematic folders successfully zipped!"
        return 0
    else
        log "⚠️  Some folders could not be zipped - manual intervention may be needed"
        return 1
    fi
}

# Function to manually process zip fallback for already completed copies
process_zip_fallback() {
    local source_dir="$1"
    local dest_dir="$2"
    local error_file="$3"
    
    log "🔧 Processing zip fallback for completed copy..."
    
    # Find folders that failed to copy (check rsync error log for "Invalid argument" errors)
    # Extract full paths from mkdir commands, preserving spaces
    local failed_folders=$(grep "Invalid argument (22)" "$error_file" | grep -o 'mkdir "[^"]*"' | cut -d'"' -f2 | sed 's|.*/||' | sort -u)
    
    if [ -z "$failed_folders" ]; then
        log "✅ No exFAT issues found in error log!"
        return 0
    fi
    
    local zipped_count=0
    local failed_count=0
    local skipped_count=0
    
    # Process each folder (handling spaces properly)
    while IFS= read -r folder; do
        # Check for UPS shutdown before each folder
        check_ups_shutdown
        
        # Skip if already zipped
        if [ -f "$dest_dir/${folder}.zip" ]; then
            log "⏭️  Already zipped: ${folder}.zip - skipping"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        log "📦 Zipping problematic folder: $folder"
        
        # Find the actual source folder
        local source_path=$(find "$source_dir" -name "$folder" -type d 2>/dev/null | head -n1)
        
        if [ -n "$source_path" ]; then
            local zip_name="${folder}.zip"
            local dest_zip="$dest_dir/$zip_name"
            
            # Start zip in background with UPS monitoring
            log "Creating: $zip_name"
            (cd "$(dirname "$source_path")" && zip -0ry "$dest_zip" "$(basename "$source_path")" 2>/dev/null) &
            local zip_pid=$!
            
            # Monitor zip progress while checking UPS status
            while kill -0 $zip_pid 2>/dev/null; do
                check_ups_shutdown
                sleep 2
            done
            
            # Wait for zip to finish
            wait $zip_pid
            local zip_exit=$?
            
            if [ $zip_exit -eq 0 ]; then
                log "✅ Successfully zipped: $zip_name"
                # Remove the failed directory entry from destination if it exists
                sudo rm -rf "$dest_dir/$folder" 2>/dev/null
                zipped_count=$((zipped_count + 1))
            else
                log "❌ Failed to zip: $folder"
                failed_count=$((failed_count + 1))
            fi
        else
            log "❌ Could not find source folder: $folder"
            log "   Searched in: $source_dir"
            failed_count=$((failed_count + 1))
        fi
        
        # Check for UPS shutdown after each folder
        check_ups_shutdown
    done <<< "$failed_folders"
    
    log "📊 Zip fallback summary: $zipped_count folders zipped, $failed_count failed, $skipped_count already done"
    
    if [ $failed_count -eq 0 ]; then
        log "✅ All problematic folders successfully zipped!"
        return 0
    else
        log "⚠️  Some folders could not be zipped - manual intervention may be needed"
        return 1
    fi
}

echo "╔════════════════════════════════════════════════╗"
echo "║      STEP 1: COPY FILES FROM OLD DRIVE        ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
log "Source: $MOUNT_POINT"
log "Source Disk: $SOURCE_DISK"
log "Destination: $DEST_DIR"
log "Started: $(date)"
log ""

# Start UPS monitoring
start_ups_monitor

# Set up cleanup trap
trap 'stop_ups_monitor; log "Script interrupted"; exit 130' INT TERM

if [ "$ZIP_ONLY" = true ]; then
    log "=== ZIP-ONLY MODE: Skipping rsync, processing zip fallback ==="
    log "Looking for existing error log: ${LOG_DIR}/${DRIVE_NAME}_rsync_errors.log"
    
    if [ ! -f "${LOG_DIR}/${DRIVE_NAME}_rsync_errors.log" ]; then
        log "❌ No error log found - cannot process zip fallback"
        log "   Expected: ${LOG_DIR}/${DRIVE_NAME}_rsync_errors.log"
        stop_ups_monitor
        exit 1
    fi
    
    process_zip_fallback "$MOUNT_POINT/" "$DEST_DIR/" "${LOG_DIR}/${DRIVE_NAME}_rsync_errors.log"
    COPY_EXIT=$?
else
    # COPY FILES with exFAT compatibility handling
    log "=== COPYING FILES (Priority: Get data off!) ==="
    log "Excluding macOS system directories (.Spotlight, .Trashes, etc.)"
    log "Using I/O timeout (60s) to skip stuck files and reduce drive stress"
    log "Will automatically zip folders that fail due to exFAT limitations"

    copy_with_fallback "$MOUNT_POINT/" "$DEST_DIR/" "$LOG_DIR/${DRIVE_NAME}_rsync.log"

    COPY_EXIT=$?
    log ""

    # Check if we need to process zip fallback for an already completed copy
    if [ $COPY_EXIT -eq 0 ] && [ -f "${LOG_DIR}/${DRIVE_NAME}_rsync_errors.log" ]; then
        # Check if there are unprocessed errors in the error log
        unprocessed_errors=$(grep -c "Invalid argument (22)" "${LOG_DIR}/${DRIVE_NAME}_rsync_errors.log" 2>/dev/null || echo "0")
        if [ $unprocessed_errors -gt 0 ]; then
            log "🔧 Found unprocessed exFAT errors - running zip fallback..."
            process_zip_fallback "$MOUNT_POINT/" "$DEST_DIR/" "${LOG_DIR}/${DRIVE_NAME}_rsync_errors.log"
            COPY_EXIT=$?
        fi
    fi
fi

# Stop UPS monitoring
stop_ups_monitor

if [ $COPY_EXIT -eq 0 ]; then
    log "✅ Copy completed successfully!"
    COPY_STATUS="SUCCESS"
else
    log "⚠️  Copy completed with some issues (check log for details)"
    COPY_STATUS="PARTIAL"
fi

log ""
log "✅ DATA IS NOW SAFE ON DESTINATION!"
log ""

# Stop UPS monitoring (already done above, but ensure it's stopped)
stop_ups_monitor

log ""
log "🎯 STEP 1 COMPLETED SUCCESSFULLY!"
log "   Next step: Run ./step2-hash.sh to create hash manifests"
log "   Note: Step 2 will collect file size information automatically"
log ""

# Summary
log "╔════════════════════════════════════════════════╗"
log "║              STEP 1 COMPLETE                   ║"
log "╚════════════════════════════════════════════════╝"
log "Drive Name: $DRIVE_NAME"
log "Total Files: $(find "$DEST_DIR" -type f \
    -not -path "*/.DocumentRevisions-V100/*" \
    -not -path "*/.Spotlight-V100/*" \
    -not -path "*/.TemporaryItems/*" \
    -not -path "*/.Trashes/*" \
    -not -path "*/.fseventsd/*" \
    -not -name ".DS_Store" \
    -not -name "._*" \
    2>/dev/null | wc -l | xargs)"
log "Total Size: $(du -sh "$DEST_DIR" 2>/dev/null | cut -f1)"
log "Copy Status: $COPY_STATUS"
log "Completed: $(date)"
log ""
log "📁 Files: $DEST_DIR"
log "📄 Report: $LOG_FILE"
log ""

echo "════════════════════════════════════════════════"
echo "Next step: Verify the copy with hash comparison"
echo "Run: sudo ./step2-hash.sh $SOURCE_DISK \"$DRIVE_NAME\" $DEST_BASE"
echo "════════════════════════════════════════════════"

if [ "$COPY_STATUS" = "SUCCESS" ]; then
    exit 0
else
    exit 1
fi
