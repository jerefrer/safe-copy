#!/bin/bash
# STEP 4: DETECT DUPLICATE FILES
# Analyzes destination manifest to find duplicate files and calculate wasted space

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <drive_name> <destination_path>"
    echo "Example: $0 \"Project_2015\" /Volumes/Exos24TB"
    echo ""
    echo "This script analyzes the destination for duplicate files"
    echo "Note: Run step2-hash.sh first to generate the manifest"
    exit 1
fi

DRIVE_NAME=$1
DEST_BASE=$2

LOG_DIR="$DEST_BASE/_logs"
MANIFEST_DIR="$DEST_BASE/_manifests"

DEST_MANIFEST="$MANIFEST_DIR/${DRIVE_NAME}_manifest.txt"
DUPES_REPORT="$LOG_DIR/${DRIVE_NAME}_duplicates.txt"

# Check if manifest exists
if [ ! -f "$DEST_MANIFEST" ]; then
    echo "ERROR: Destination manifest not found: $DEST_MANIFEST"
    echo "Please run step2-hash.sh first"
    exit 1
fi

echo "╔════════════════════════════════════════════════╗"
echo "║      STEP 4: DUPLICATE DETECTION              ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
echo "Analyzing destination for duplicate files..."
echo ""

# Analyze duplicates
awk '
BEGIN {
    FS = ","
    total_wasted = 0
}

/^%%%/ || /^#/ || /^$/ {
    next
}

/^[0-9]/ {
    size = $1
    hash = $2
    filepath = $3
    for (i = 4; i <= NF; i++) filepath = filepath "," $i
    
    hashes[hash] = hashes[hash] (hashes[hash] ? "\n      " : "") filepath
    sizes[hash] = size
    count[hash]++
}

END {
    dup_count = 0
    
    for (h in count) {
        if (count[h] > 1) {
            dup_count++
            size_mb = sizes[h] / 1024 / 1024
            wasted = sizes[h] * (count[h] - 1)
            wasted_mb = wasted / 1024 / 1024
            total_wasted += wasted
            
            printf "\nDuplicate Set #%d:\n", dup_count
            printf "  Hash: %s\n", substr(h, 1, 16) "..."
            printf "  File size: %s bytes (%.2f MB)\n", sizes[h], size_mb
            printf "  Copies: %d\n", count[h]
            printf "  Wasted space: %s bytes (%.2f MB)\n", wasted, wasted_mb
            printf "  Files:\n      %s\n", hashes[h]
        }
    }
    
    printf "\n============================================\n"
    if (dup_count == 0) {
        printf "✅ No duplicates found!\n"
    } else {
        printf "Total duplicate sets: %d\n", dup_count
        printf "Total wasted space: %s bytes (%.2f GB)\n", total_wasted, total_wasted/1024/1024/1024
    }
}
' "$DEST_MANIFEST" > "$DUPES_REPORT"

# Extract summary for display
DUPE_COUNT=$(grep -c "Duplicate Set" "$DUPES_REPORT" || echo "0")
WASTED_SPACE=$(grep "Total wasted space" "$DUPES_REPORT" | awk '{print $4, $5, $6}')

echo "=== DUPLICATE DETECTION RESULTS ==="
if [ "$DUPE_COUNT" -eq 0 ]; then
    echo "✅ No duplicate files found"
else
    echo "⚠️  Found $DUPE_COUNT sets of duplicate files"
    echo "   Wasted space: $WASTED_SPACE"
    echo "   See detailed report: $DUPES_REPORT"
fi

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║              STEP 4 COMPLETE                   ║"
echo "╚════════════════════════════════════════════════╝"
echo "Duplicate sets found: $DUPE_COUNT"
[ "$DUPE_COUNT" != "0" ] && echo "Wasted space: $WASTED_SPACE"
echo "Report: $DUPES_REPORT"
echo ""
echo "════════════════════════════════════════════════"
echo "All steps complete!"
echo "You can now safely unmount the source drive"
echo "════════════════════════════════════════════════"

exit 0
