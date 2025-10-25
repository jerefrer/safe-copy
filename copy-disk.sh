#!/bin/bash
# OLD DRIVE RUSHES RECOVERY - With progress feedback

if [ "$#" -ne 3 ]; then
    echo "Usage: sudo $0 <source_disk> <drive_name> <destination_path>"
    echo "Example: sudo $0 /dev/disk4s2 \"Project_2015\" /Volumes/Exos24TB"
    echo ""
    echo "Note: Use Disk Arbitrator to mount the source disk READ-ONLY before running this script"
    exit 1
fi

SOURCE_DISK=$1
DRIVE_NAME=$2
DEST_BASE=$3

DEST_DIR="$DEST_BASE/video_rushes/$DRIVE_NAME"
LOG_DIR="$DEST_BASE/_logs"
MANIFEST_DIR="$DEST_BASE/_manifests"

# Check if destination exists
if [ ! -d "$DEST_BASE" ]; then
    echo "ERROR: Destination path does not exist: $DEST_BASE"
    exit 1
fi

mkdir -p "$DEST_DIR" "$LOG_DIR" "$MANIFEST_DIR"

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
echo "║      OLD DRIVE RECOVERY - COPY FIRST          ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
echo "Source: $MOUNT_POINT" | tee "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Source Disk: $SOURCE_DISK" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Destination: $DEST_DIR" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Started: $(date)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

# STEP 1: COPY IMMEDIATELY
echo "=== STEP 1: COPYING FILES (Priority: Get data off!) ===" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
sudo rsync -avhx \
  --progress \
  --stats \
  --log-file="$LOG_DIR/${DRIVE_NAME}_rsync.log" \
  "$MOUNT_POINT/" "$DEST_DIR/" 2>&1 | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

RSYNC_EXIT=${PIPESTATUS[0]}
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

if [ $RSYNC_EXIT -eq 0 ]; then
    echo "✅ Copy completed successfully!" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    COPY_STATUS="SUCCESS"
else
    echo "⚠️  Copy completed with errors (exit code: $RSYNC_EXIT)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    COPY_STATUS="PARTIAL"
fi
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

# STEP 2: DATA IS SAFE
echo "=== STEP 2: Data copied ===" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "✅ You can now unmount the source drive using Disk Arbitrator" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "🎉 DATA IS NOW SAFE ON DESTINATION!" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

# STEP 3: Ask about source verification
echo "=== STEP 3: SOURCE VERIFICATION (Optional) ===" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Your data is now safely copied to the destination." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Do you want to verify against the source drive?" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "This requires reading the source again (with PROGRESS feedback)." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
read -p "Verify source? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "=== FILE-BY-FILE VERIFICATION WITH PROGRESS ===" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    # Check if still mounted
    MOUNT_POINT=$(diskutil info "$SOURCE_DISK" | grep "Mount Point" | cut -d: -f2 | xargs)
    if [ -z "$MOUNT_POINT" ] || [ "$MOUNT_POINT" = "" ]; then
        echo "Source drive is not mounted. Please mount it read-only again using Disk Arbitrator."
        read -p "Press Enter when ready..."
        MOUNT_POINT=$(diskutil info "$SOURCE_DISK" | grep "Mount Point" | cut -d: -f2 | xargs)
    fi
    
    # Count total files first
    echo "Counting files..." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    TOTAL_FILES=$(find "$MOUNT_POINT" -type f | wc -l | xargs)
    echo "Found $TOTAL_FILES files to verify" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    # Verify file by file with progress
    CURRENT=0
    MATCHES=0
    MISMATCHES=0
    MISSING=0
    
    echo "Verifying files..." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    while IFS= read -r source_file; do
        CURRENT=$((CURRENT + 1))
        
        # Get relative path
        rel_path="${source_file#$MOUNT_POINT/}"
        dest_file="$DEST_DIR/$rel_path"
        
        # Progress indicator
        percent=$((CURRENT * 100 / TOTAL_FILES))
        printf "\r[%3d%%] %d/%d: %s" "$percent" "$CURRENT" "$TOTAL_FILES" "$(basename "$source_file")" | cut -c1-80
        
        # Check if destination file exists
        if [ ! -f "$dest_file" ]; then
            echo "" >> "$LOG_DIR/${DRIVE_NAME}_verify.log"
            echo "MISSING: $rel_path" >> "$LOG_DIR/${DRIVE_NAME}_verify.log"
            MISSING=$((MISSING + 1))
            continue
        fi
        
        # Compare checksums
        source_hash=$(shasum -a 256 "$source_file" | awk '{print $1}')
        dest_hash=$(shasum -a 256 "$dest_file" | awk '{print $1}')
        
        if [ "$source_hash" = "$dest_hash" ]; then
            MATCHES=$((MATCHES + 1))
        else
            echo "" >> "$LOG_DIR/${DRIVE_NAME}_verify.log"
            echo "MISMATCH: $rel_path" >> "$LOG_DIR/${DRIVE_NAME}_verify.log"
            echo "  Source: $source_hash" >> "$LOG_DIR/${DRIVE_NAME}_verify.log"
            echo "  Dest:   $dest_hash" >> "$LOG_DIR/${DRIVE_NAME}_verify.log"
            MISMATCHES=$((MISMATCHES + 1))
        fi
    done < <(find "$MOUNT_POINT" -type f)
    
    echo "" # New line after progress
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "=== VERIFICATION RESULTS ===" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "Total files checked: $TOTAL_FILES" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "✅ Matches: $MATCHES" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    if [ $MISMATCHES -gt 0 ]; then
        echo "❌ Mismatches: $MISMATCHES" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    fi
    
    if [ $MISSING -gt 0 ]; then
        echo "⚠️  Missing: $MISSING" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    fi
    
    if [ $MISMATCHES -eq 0 ] && [ $MISSING -eq 0 ]; then
        echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        echo "✅ ✅ ✅ VERIFICATION PASSED ✅ ✅ ✅" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        echo "All files match perfectly!" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        VERIFY_STATUS="VERIFIED"
    else
        echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        echo "❌ VERIFICATION ISSUES FOUND" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        echo "See details in: $LOG_DIR/${DRIVE_NAME}_verify.log" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        VERIFY_STATUS="FAILED"
    fi
else
    echo "Skipping source verification." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    VERIFY_STATUS="SKIPPED"
fi

# Summary
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "╔════════════════════════════════════════════════╗" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "║                    SUMMARY                     ║" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "╚════════════════════════════════════════════════╝" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Drive Name: $DRIVE_NAME" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Total Files: $(find "$DEST_DIR" -type f | wc -l | xargs)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Total Size: $(du -sh "$DEST_DIR" | cut -f1)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Copy Status: $COPY_STATUS" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Verification: $VERIFY_STATUS" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
if [ "$VERIFY_STATUS" = "VERIFIED" ]; then
    echo "  ✅ $MATCHES files verified" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
elif [ "$VERIFY_STATUS" = "FAILED" ]; then
    echo "  ✅ Matches: $MATCHES" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "  ❌ Mismatches: $MISMATCHES" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "  ⚠️  Missing: $MISSING" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
fi
echo "Completed: $(date)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "📁 Files: $DEST_DIR" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
if [ "$VERIFY_STATUS" = "FAILED" ]; then
    echo "📋 Detailed errors: $LOG_DIR/${DRIVE_NAME}_verify.log" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
fi
echo "📄 Full Report: $LOG_DIR/${DRIVE_NAME}_report.txt" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

if [ "$VERIFY_STATUS" = "VERIFIED" ] && [ "$COPY_STATUS" = "SUCCESS" ]; then
    exit 0
else
    exit 1
fi