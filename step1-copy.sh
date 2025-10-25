#!/bin/bash
# STEP 1: COPY FILES FROM SOURCE TO DESTINATION
# This script copies files from an old drive to a destination, prioritizing data safety

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
echo "║      STEP 1: COPY FILES FROM OLD DRIVE        ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
echo "Source: $MOUNT_POINT" | tee "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Source Disk: $SOURCE_DISK" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Destination: $DEST_DIR" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Started: $(date)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

# COPY FILES
echo "=== COPYING FILES (Priority: Get data off!) ===" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
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
echo "✅ DATA IS NOW SAFE ON DESTINATION!" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

# Summary
echo "╔════════════════════════════════════════════════╗" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "║              STEP 1 COMPLETE                   ║" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "╚════════════════════════════════════════════════╝" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Drive Name: $DRIVE_NAME" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Total Files: $(find "$DEST_DIR" -type f 2>/dev/null | wc -l | xargs)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Total Size: $(du -sh "$DEST_DIR" 2>/dev/null | cut -f1)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Copy Status: $COPY_STATUS" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Completed: $(date)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "📁 Files: $DEST_DIR" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "📄 Report: $LOG_DIR/${DRIVE_NAME}_report.txt" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

echo "════════════════════════════════════════════════"
echo "Next step: Verify the copy with hash comparison"
echo "Run: sudo ./step2-hash.sh $SOURCE_DISK \"$DRIVE_NAME\" $DEST_BASE"
echo "════════════════════════════════════════════════"

if [ "$COPY_STATUS" = "SUCCESS" ]; then
    exit 0
else
    exit 1
fi
