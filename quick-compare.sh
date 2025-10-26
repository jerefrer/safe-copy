#!/bin/bash
# QUICK COMPARE - File size based (no hashing)

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <source_folder> <destination_folder>"
    echo "Example: $0 /Volumes/OldDrive /Volumes/NewDrive/backup"
    exit 1
fi

SOURCE="${1%/}"  # Remove trailing slash
DEST="${2%/}"    # Remove trailing slash

echo "╔════════════════════════════════════════════════╗"
echo "║        QUICK SIZE-BASED COMPARISON            ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
echo "Source: $SOURCE"
echo "Destination: $DEST"
echo ""

# Verify directories exist
if [ ! -d "$SOURCE" ]; then
    echo "❌ Source directory does not exist: $SOURCE"
    exit 1
fi

if [ ! -d "$DEST" ]; then
    echo "❌ Destination directory does not exist: $DEST"
    exit 1
fi
echo ""

# Count files
echo "Counting files..."
SOURCE_COUNT=$(find "$SOURCE" -type f | wc -l | xargs)
DEST_COUNT=$(find "$DEST" -type f | wc -l | xargs)

echo "Source files: $SOURCE_COUNT"
echo "Destination files: $DEST_COUNT"
echo ""

if [ "$SOURCE_COUNT" -ne "$DEST_COUNT" ]; then
    echo "⚠️  WARNING: File count mismatch!"
    echo ""
fi

# Compare file by file
CURRENT=0
MATCHES=0
SIZE_MISMATCHES=0
MISSING=0

echo "Comparing file sizes..."
echo ""

while IFS= read -r source_file; do
    CURRENT=$((CURRENT + 1))
    
    # Get relative path
    rel_path="${source_file#$SOURCE/}"
    dest_file="$DEST/$rel_path"
    
    # Debug first file
    if [ $CURRENT -eq 1 ]; then
        echo "DEBUG: First file comparison:" >&2
        echo "  Source file: $source_file" >&2
        echo "  SOURCE var: $SOURCE" >&2
        echo "  Relative path: $rel_path" >&2
        echo "  Dest file: $dest_file" >&2
        echo "" >&2
    fi
    
    # Progress
    percent=$((CURRENT * 100 / SOURCE_COUNT))
    printf "\r[%3d%%] %d/%d" "$percent" "$CURRENT" "$SOURCE_COUNT"
    
    # Check if destination exists
    if [ ! -f "$dest_file" ]; then
        echo "" >&2
        echo "MISSING: $rel_path" >&2
        MISSING=$((MISSING + 1))
        continue
    fi
    
    # Compare sizes
    source_size=$(stat -f%z "$source_file" 2>/dev/null || stat -c%s "$source_file" 2>/dev/null)
    dest_size=$(stat -f%z "$dest_file" 2>/dev/null || stat -c%s "$dest_file" 2>/dev/null)
    
    if [ "$source_size" = "$dest_size" ]; then
        MATCHES=$((MATCHES + 1))
    else
        echo "" >&2
        echo "SIZE MISMATCH: $rel_path" >&2
        echo "  Source: $source_size bytes" >&2
        echo "  Dest:   $dest_size bytes" >&2
        SIZE_MISMATCHES=$((SIZE_MISMATCHES + 1))
    fi
done < <(find "$SOURCE" -type f)

echo "" # New line after progress
echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║                   RESULTS                      ║"
echo "╚════════════════════════════════════════════════╝"
echo "Total files checked: $SOURCE_COUNT"
echo "✅ Size matches: $MATCHES"

if [ $SIZE_MISMATCHES -gt 0 ]; then
    echo "❌ Size mismatches: $SIZE_MISMATCHES"
fi

if [ $MISSING -gt 0 ]; then
    echo "⚠️  Missing files: $MISSING"
fi

echo ""

if [ $SIZE_MISMATCHES -eq 0 ] && [ $MISSING -eq 0 ]; then
    echo "✅ ✅ ✅ QUICK CHECK PASSED ✅ ✅ ✅"
    echo "All files present with matching sizes!"
    echo ""
    echo "Note: This doesn't verify content integrity."
    echo "For critical data, run full hash verification."
    exit 0
else
    echo "❌ ISSUES FOUND"
    echo "Consider running full hash verification."
    exit 1
fi