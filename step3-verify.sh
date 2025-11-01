#!/bin/bash
# STEP 3: VERIFY COPY INTEGRITY
# Compares hash manifests to verify all files copied correctly

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <drive_name> <destination_path>"
    echo "Example: $0 \"Project_2015\" /Volumes/Exos24TB"
    echo ""
    echo "This script compares source and destination hash manifests"
    echo "Note: Run step2-hash.sh first to generate manifests"
    exit 1
fi

DRIVE_NAME=$1
DEST_BASE=$2

DEST_DIR="$DEST_BASE/$DRIVE_NAME"
LOG_DIR="$DEST_BASE/_logs"
MANIFEST_DIR="$DEST_BASE/_manifests"

SOURCE_MANIFEST="$MANIFEST_DIR/${DRIVE_NAME}_source_manifest.txt"
DEST_MANIFEST="$MANIFEST_DIR/${DRIVE_NAME}_manifest.txt"
VERIFY_LOG="$LOG_DIR/${DRIVE_NAME}_verify_details.txt"

# Check if manifests exist
if [ ! -f "$SOURCE_MANIFEST" ]; then
    echo "ERROR: Source manifest not found: $SOURCE_MANIFEST"
    echo "Please run step2-hash.sh first"
    exit 1
fi

if [ ! -f "$DEST_MANIFEST" ]; then
    echo "ERROR: Destination manifest not found: $DEST_MANIFEST"
    echo "Please run step2-hash.sh first"
    exit 1
fi

echo "╔════════════════════════════════════════════════╗"
echo "║      STEP 3: VERIFY COPY INTEGRITY            ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
echo "Comparing manifests to verify copy integrity..."
echo "(Excluding macOS system files and metadata)"
echo ""

# Parse both manifests and compare
# Create temporary sorted hash lists (hash only, for comparison)
# Format is CSV: size,hash,filename
# Use sort -u to remove any duplicate entries from interrupted hashing
# Exclude macOS system files/directories
awk -F',' '/^[0-9]/ && !/\.DS_Store/ && !/\/\._/ && !/\.DocumentRevisions-V100/ && !/\.Spotlight-V100/ && !/\.TemporaryItems/ && !/\.Trashes/ && !/\.fseventsd/ {print $2}' "$SOURCE_MANIFEST" | sort -u > /tmp/source_hashes_$$.txt
awk -F',' '/^[0-9]/ && !/\.DS_Store/ && !/\/\._/ && !/\.DocumentRevisions-V100/ && !/\.Spotlight-V100/ && !/\.TemporaryItems/ && !/\.Trashes/ && !/\.fseventsd/ {print $2}' "$DEST_MANIFEST" | sort -u > /tmp/dest_hashes_$$.txt

# Count files
SOURCE_FILE_COUNT=$(wc -l < /tmp/source_hashes_$$.txt | xargs)
DEST_FILE_COUNT=$(wc -l < /tmp/dest_hashes_$$.txt | xargs)

echo "Source files: $SOURCE_FILE_COUNT"
echo "Destination files: $DEST_FILE_COUNT"
echo ""

# Find missing files (in source but not in destination)
comm -23 /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt > /tmp/missing_$$.txt
MISSING_COUNT=$(wc -l < /tmp/missing_$$.txt | xargs)

# Find extra files (in destination but not in source - shouldn't happen)
comm -13 /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt > /tmp/extra_$$.txt
EXTRA_COUNT=$(wc -l < /tmp/extra_$$.txt | xargs)

# Perfect matches
comm -12 /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt > /tmp/matches_$$.txt
MATCH_COUNT=$(wc -l < /tmp/matches_$$.txt | xargs)

echo "=== VERIFICATION RESULTS ==="
echo "✅ Perfect matches: $MATCH_COUNT files"

if [ $MISSING_COUNT -gt 0 ]; then
    echo "❌ Missing from destination: $MISSING_COUNT files"
    echo "" >> "$VERIFY_LOG"
    echo "MISSING FILES (in source but not in destination):" >> "$VERIFY_LOG"
    while read hash; do
        grep "$hash" "$SOURCE_MANIFEST" >> "$VERIFY_LOG"
    done < /tmp/missing_$$.txt
fi

if [ $EXTRA_COUNT -gt 0 ]; then
    echo "⚠️  Extra files in destination: $EXTRA_COUNT files"
    echo "" >> "$VERIFY_LOG"
    echo "EXTRA FILES (in destination but not in source):" >> "$VERIFY_LOG"
    while read hash; do
        grep "$hash" "$DEST_MANIFEST" >> "$VERIFY_LOG"
    done < /tmp/extra_$$.txt
fi

# Clean up temp files
rm -f /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt /tmp/missing_$$.txt /tmp/extra_$$.txt /tmp/matches_$$.txt

echo ""

if [ $MISSING_COUNT -eq 0 ] && [ $EXTRA_COUNT -eq 0 ] && [ $SOURCE_FILE_COUNT -eq $DEST_FILE_COUNT ]; then
    echo "✅ ✅ ✅ VERIFICATION PASSED ✅ ✅ ✅"
    echo "All $MATCH_COUNT files copied perfectly!"
    VERIFY_STATUS="VERIFIED"
else
    echo "❌ VERIFICATION ISSUES FOUND"
    echo "See details in: $VERIFY_LOG"
    VERIFY_STATUS="FAILED"
fi

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║              STEP 3 COMPLETE                   ║"
echo "╚════════════════════════════════════════════════╝"
echo "Verification Status: $VERIFY_STATUS"
echo "Perfect matches: $MATCH_COUNT files"
[ $MISSING_COUNT -gt 0 ] && echo "Missing: $MISSING_COUNT files"
[ $EXTRA_COUNT -gt 0 ] && echo "Extra: $EXTRA_COUNT files"
[ -f "$VERIFY_LOG" ] && echo "Details: $VERIFY_LOG"
echo ""
echo "════════════════════════════════════════════════"
echo "Next step: Check for duplicate files"
echo "Run: ./step4-duplicates.sh \"$DRIVE_NAME\" $DEST_BASE"
echo "════════════════════════════════════════════════"

if [ "$VERIFY_STATUS" = "VERIFIED" ]; then
    exit 0
else
    exit 1
fi
