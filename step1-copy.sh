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
LOG_FILE="$LOG_DIR/${DRIVE_NAME}_report.txt"

# Logging function
log() {
    echo "$@" | tee -a "$LOG_FILE"
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
log "Source: $MOUNT_POINT"
log "Source Disk: $SOURCE_DISK"
log "Destination: $DEST_DIR"
log "Started: $(date)"
log ""

# COPY FILES
log "=== COPYING FILES (Priority: Get data off!) ==="
log "Excluding macOS system directories (.Spotlight, .Trashes, etc.)"
sudo rsync -avhx \
  --progress \
  --stats \
  --exclude='.DocumentRevisions-V100' \
  --exclude='.Spotlight-V100' \
  --exclude='.TemporaryItems' \
  --exclude='.Trashes' \
  --exclude='.fseventsd' \
  --exclude='.DS_Store' \
  --exclude='._*' \
  --log-file="$LOG_DIR/${DRIVE_NAME}_rsync.log" \
  "$MOUNT_POINT/" "$DEST_DIR/" 2>&1 | tee -a "$LOG_FILE"

RSYNC_EXIT=${PIPESTATUS[0]}
log ""

if [ $RSYNC_EXIT -eq 0 ]; then
    log "✅ Copy completed successfully!"
    COPY_STATUS="SUCCESS"
else
    log "⚠️  Copy completed with errors (exit code: $RSYNC_EXIT)"
    COPY_STATUS="PARTIAL"
fi

log ""
log "✅ DATA IS NOW SAFE ON DESTINATION!"
log ""

# Collect file sizes for accurate progress tracking in step 2
log "Collecting file size information for progress tracking..."
SIZES_FILE="$MANIFEST_DIR/${DRIVE_NAME}_sizes.txt"
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
log "✅ File sizes collected: $SIZES_FILE"
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
