#!/bin/bash
# STEP 3: VERIFY COPY INTEGRITY
# Compares hash manifests to verify all files copied correctly

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
    echo "Usage: $0 <drive_name> <destination_path> [--detailed] [--manifest-dir <path>]"
    echo "Example: $0 \"Project_2015\" /Volumes/Exos24TB"
    echo "Example: $0 \"Project_2015\" /Volumes/Exos24TB --detailed"
    echo "Example: $0 \"3\" /Volumes/ARCHIVE01 --manifest-dir ./manifests/_manifests"
    echo "Example: $0 \"3\" /Volumes/ARCHIVE01 --detailed --manifest-dir ./manifests/_manifests"
    echo ""
    echo "This script compares source and destination hash manifests"
    echo "Note: Run step2-hash.sh first to generate manifests"
    echo ""
    echo "Options:"
    echo "  --detailed       Show list of missing/corrupted files (slower for large sets)"
    echo "  --manifest-dir   Path to _manifests directory (default: destination_path/_manifests)"
    exit 1
fi

DRIVE_NAME=$1
DEST_BASE=$2
DETAILED_MODE=""
MANIFEST_BASE="$DEST_BASE"

# Parse optional arguments
shift 2  # Remove first two arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --detailed)
            DETAILED_MODE="--detailed"
            shift
            ;;
        --manifest-dir)
            MANIFEST_BASE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Set up paths
DEST_DIR="$DEST_BASE/$DRIVE_NAME"

# If manifest folder is different from destination, create local log directory
if [ "$MANIFEST_BASE" = "$DEST_BASE" ]; then
    # Original behavior: logs in destination
    LOG_DIR="$DEST_BASE/_logs"
else
    # Local behavior: logs in current directory
    LOG_DIR="./_logs"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
fi

# MANIFEST_DIR is now the exact path provided (not _manifests subdirectory)
MANIFEST_DIR="$MANIFEST_BASE"

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
# Handle zip files: convert "zipfile:originalpath" to just "originalpath" for comparison
# Use sort -u to remove any duplicate entries from interrupted hashing
# Exclude macOS system files/directories

# Process source manifest (extract hash and normalize paths)
awk -F',' '
/^[0-9]/ && !/\.DS_Store/ && !/\/\._/ && !/\.DocumentRevisions-V100/ && !/\.Spotlight-V100/ && !/\.TemporaryItems/ && !/\.Trashes/ && !/\.fseventsd/ {
    # Skip entries without proper hash (size,hash,filename format)
    if (NF < 3 || $2 == "" || $3 == "") {
        next
    }
    
    hash = $2
    filepath = $3
    
    # Handle zip file format: "zipfile:originalpath" -> "originalpath"
    if (index(filepath, ":") > 0) {
        # Split on ":" and take the second part (original path)
        split(filepath, parts, ":")
        normalized_path = parts[2]
    } else {
        normalized_path = filepath
    }
    
    # Remove source mount point prefix if present
    if (index(normalized_path, "/Volumes/8TB safety tea01/") == 1) {
        normalized_path = substr(normalized_path, length("/Volumes/8TB safety tea01/") + 1)
    }
    
    # Only output if we have both hash and path (allow empty hash for empty files)
    if (hash != "" && normalized_path != "") {
        # Create a mapping: hash -> normalized_path
        print hash "|" normalized_path
    }
}' "$SOURCE_MANIFEST" | sort -u > /tmp/source_hashes_$$.txt

# Process destination manifest (extract hash and normalize paths)
awk -F',' '
/^[0-9]/ && !/\.DS_Store/ && !/\/\._/ && !/\.DocumentRevisions-V100/ && !/\.Spotlight-V100/ && !/\.TemporaryItems/ && !/\.Trashes/ && !/\.fseventsd/ {
    # Skip entries without proper format (size,hash,filename)
    if (NF < 3 || $3 == "") {
        next
    }
    
    hash = $2
    filepath = $3
    
    # Handle zip file format: "zipfile:originalpath" -> "originalpath"
    if (index(filepath, ":") > 0) {
        # Split on ":" and take the second part (original path)
        split(filepath, parts, ":")
        normalized_path = parts[2]
    } else {
        normalized_path = filepath
    }
    
    # Remove destination mount point prefix if present
    if (index(normalized_path, "/Volumes/ARCHIVE01/") == 1) {
        # Extract drive name and remove it
        # /Volumes/ARCHIVE01/3/folder -> folder
        normalized_path = substr(normalized_path, length("/Volumes/ARCHIVE01/") + 1)
        # Remove drive name part if present
        if (index(normalized_path, "3/") == 1) {
            normalized_path = substr(normalized_path, 3)
        }
    }
    
    # Only output if we have both hash and path (allow empty hash for empty files)
    if (hash != "" && normalized_path != "") {
        # Create a mapping: hash -> normalized_path
        print hash "|" normalized_path
    }
}' "$DEST_MANIFEST" | sort -u > /tmp/dest_hashes_$$.txt

# Extract just hashes for comparison
cut -d'|' -f1 /tmp/source_hashes_$$.txt > /tmp/source_hashes_only_$$.txt
cut -d'|' -f1 /tmp/dest_hashes_$$.txt > /tmp/dest_hashes_only_$$.txt

# Count files
SOURCE_FILE_COUNT=$(wc -l < /tmp/source_hashes_$$.txt | xargs)
DEST_FILE_COUNT=$(wc -l < /tmp/dest_hashes_$$.txt | xargs)

echo "Source files: $SOURCE_FILE_COUNT"
echo "Destination files: $DEST_FILE_COUNT"

# Count files in source (should be all regular files, no zips)
SOURCE_REGULAR_FILES=$SOURCE_FILE_COUNT
SOURCE_ZIP_FILES=0
SOURCE_ZIP_CONTENTS=0

# Count files in destination (regular files + files inside zips)
DEST_ZIP_FILES=$(grep -c "\.zip" "$DEST_MANIFEST" 2>/dev/null)
if [ -z "$DEST_ZIP_FILES" ]; then
    DEST_ZIP_FILES=0
fi

DEST_ZIP_CONTENTS=$(grep -c ":" "$DEST_MANIFEST" 2>/dev/null)
if [ -z "$DEST_ZIP_CONTENTS" ]; then
    DEST_ZIP_CONTENTS=0
fi

DEST_REGULAR_FILES=$((DEST_FILE_COUNT - DEST_ZIP_CONTENTS))

echo "  Regular files: $SOURCE_REGULAR_FILES → $DEST_REGULAR_FILES"
echo "  Zip files: $SOURCE_ZIP_FILES → $DEST_ZIP_FILES"
echo "  Files inside zips: $SOURCE_ZIP_CONTENTS → $DEST_ZIP_CONTENTS"
echo ""

# Find missing files (in source but not in destination)
comm -23 /tmp/source_hashes_only_$$.txt /tmp/dest_hashes_only_$$.txt > /tmp/missing_$$.txt
MISSING_COUNT=$(wc -l < /tmp/missing_$$.txt | xargs)

# Find extra files (in destination but not in source - shouldn't happen)
comm -13 /tmp/source_hashes_only_$$.txt /tmp/dest_hashes_only_$$.txt > /tmp/extra_$$.txt
EXTRA_COUNT=$(wc -l < /tmp/extra_$$.txt | xargs)

# Perfect matches
comm -12 /tmp/source_hashes_only_$$.txt /tmp/dest_hashes_only_$$.txt > /tmp/matches_$$.txt
MATCH_COUNT=$(wc -l < /tmp/matches_$$.txt | xargs)

# Check for hash mismatches (corruption) - compare full manifest entries
# Create associative arrays for hash comparison
awk -F',' '
/^[0-9]/ && !/\.DS_Store/ && !/\/\._/ && !/\.DocumentRevisions-V100/ && !/\.Spotlight-V100/ && !/\.TemporaryItems/ && !/\.Trashes/ && !/\.fseventsd/ {
    # Normalize paths for comparison
    filepath = $3
    if (index(filepath, ":") > 0) {
        split(filepath, parts, ":")
        normalized_path = parts[2]
    } else {
        normalized_path = filepath
    }
    # Store hash for this normalized path
    hash_map[normalized_path] = $2
    size_map[normalized_path] = $1
    full_entry[normalized_path] = $0
}
END {
    for (path in hash_map) {
        print hash_map[path] "|" size_map[path] "|" path "|" full_entry[path]
    }
}' "$SOURCE_MANIFEST" | sort > /tmp/source_map_$$.txt

awk -F',' '
/^[0-9]/ && !/\.DS_Store/ && !/\/\._/ && !/\.DocumentRevisions-V100/ && !/\.Spotlight-V100/ && !/\.TemporaryItems/ && !/\.Trashes/ && !/\.fseventsd/ {
    # Normalize paths for comparison
    filepath = $3
    if (index(filepath, ":") > 0) {
        split(filepath, parts, ":")
        normalized_path = parts[2]
    } else {
        normalized_path = filepath
    }
    # Store hash for this normalized path
    hash_map[normalized_path] = $2
    size_map[normalized_path] = $1
    full_entry[normalized_path] = $0
}
END {
    for (path in hash_map) {
        print hash_map[path] "|" size_map[path] "|" path "|" full_entry[path]
    }
}' "$DEST_MANIFEST" | sort > /tmp/dest_map_$$.txt

# Find corruption (same file path but different hash)
join -t'|' -1 3 -2 3 /tmp/source_map_$$.txt /tmp/dest_map_$$.txt | awk -F'|' '$1 != $4 {print $3}' > /tmp/corrupted_$$.txt
CORRUPTED_COUNT=$(wc -l < /tmp/corrupted_$$.txt | xargs)

echo "=== VERIFICATION RESULTS ==="
echo "✅ Perfect matches: $MATCH_COUNT files"

if [ $MISSING_COUNT -gt 0 ]; then
    echo "❌ Missing from destination: $MISSING_COUNT files"
    echo "" >> "$VERIFY_LOG"
    echo "MISSING FILES (in source but not in destination):" >> "$VERIFY_LOG"
    echo "Total missing: $MISSING_COUNT" >> "$VERIFY_LOG"
    
    if [ "$DETAILED_MODE" = "--detailed" ]; then
        echo "Generating detailed list (optimized method)..."
        
        # Create fast lookup table: hash -> normalized filepath from source manifest
        awk -F',' '
/^[0-9]/ && !/\.DS_Store/ && !/\/\._/ && !/\.DocumentRevisions-V100/ && !/\.Spotlight-V100/ && !/\.TemporaryItems/ && !/\.Trashes/ && !/\.fseventsd/ {
    hash = $2
    filepath = $3
    # Remove mount point prefix
    if (index(filepath, "/Volumes/8TB safety tea01/") == 1) {
        filepath = substr(filepath, length("/Volumes/8TB safety tea01/") + 1)
    }
    # Handle zip format
    if (index(filepath, ":") > 0) {
        split(filepath, parts, ":")
        filepath = parts[2]
    }
    print hash "|" filepath
}' "$SOURCE_MANIFEST" | sort > /tmp/source_lookup_$$.txt
        
        echo "" >> "$VERIFY_LOG"
        echo "Detailed missing file list:" >> "$VERIFY_LOG"
        while read hash; do
            # Fast lookup using grep on sorted lookup table
            filepath=$(grep "^$hash|" /tmp/source_lookup_$$.txt | cut -d'|' -f2 | head -1)
            if [ -n "$filepath" ]; then
                echo "  - $filepath" >> "$VERIFY_LOG"
            fi
        done < /tmp/missing_$$.txt
        echo "✅ Detailed list saved to: $VERIFY_LOG"
        rm -f /tmp/source_lookup_$$.txt
    else
        echo "  Run with --detailed flag to see specific file names" >> "$VERIFY_LOG"
        echo "  Example: $0 \"$DRIVE_NAME\" \"$DEST_BASE\" --detailed" >> "$VERIFY_LOG"
    fi
fi

if [ $CORRUPTED_COUNT -gt 0 ]; then
    echo "🚨 CORRUPTED FILES: $CORRUPTED_COUNT files"
    echo "" >> "$VERIFY_LOG"
    echo "CORRUPTED FILES (hash mismatch between source and destination):" >> "$VERIFY_LOG"
    echo "Total corrupted: $CORRUPTED_COUNT" >> "$VERIFY_LOG"
    
    if [ "$DETAILED_MODE" = "--detailed" ]; then
        echo "Generating detailed corruption list..."
        echo "" >> "$VERIFY_LOG"
        echo "Detailed corrupted file list:" >> "$VERIFY_LOG"
        while read filepath; do
            echo "  - $filepath" >> "$VERIFY_LOG"
            # Get source and destination hashes for comparison
            source_entry=$(grep ":$filepath$" "$SOURCE_MANIFEST" | head -1)
            dest_entry=$(grep ":$filepath$" "$DEST_MANIFEST" | head -1)
            if [ -n "$source_entry" ] && [ -n "$dest_entry" ]; then
                source_hash=$(echo "$source_entry" | cut -d',' -f2)
                dest_hash=$(echo "$dest_entry" | cut -d',' -f2)
                echo "    Source hash: $source_hash" >> "$VERIFY_LOG"
                echo "    Dest hash:   $dest_hash" >> "$VERIFY_LOG"
            fi
        done < /tmp/corrupted_$$.txt
        echo "✅ Detailed corruption list saved to: $VERIFY_LOG"
    else
        echo "  Run with --detailed flag to see specific file names" >> "$VERIFY_LOG"
        echo "  Example: $0 \"$DRIVE_NAME\" \"$DEST_BASE\" --detailed" >> "$VERIFY_LOG"
    fi
fi

if [ $EXTRA_COUNT -gt 0 ]; then
    echo "⚠️  Extra files in destination: $EXTRA_COUNT files"
    echo "" >> "$VERIFY_LOG"
    echo "EXTRA FILES (in destination but not in source):" >> "$VERIFY_LOG"
    echo "Total extra: $EXTRA_COUNT" >> "$VERIFY_LOG"
    echo "  Run with --detailed flag to see specific file names" >> "$VERIFY_LOG"
fi

# Clean up temp files
rm -f /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt /tmp/source_hashes_only_$$.txt /tmp/dest_hashes_only_$$.txt /tmp/missing_$$.txt /tmp/extra_$$.txt /tmp/matches_$$.txt /tmp/source_map_$$.txt /tmp/dest_map_$$.txt /tmp/corrupted_$$.txt /tmp/source_lookup_$$.txt

echo ""

if [ $MISSING_COUNT -eq 0 ] && [ $EXTRA_COUNT -eq 0 ] && [ $CORRUPTED_COUNT -eq 0 ] && [ $SOURCE_FILE_COUNT -eq $DEST_FILE_COUNT ]; then
    echo "✅ ✅ ✅ VERIFICATION PASSED ✅ ✅ ✅"
    echo "All $MATCH_COUNT files copied perfectly!"
    VERIFY_STATUS="VERIFIED"
else
    echo "❌ VERIFICATION ISSUES FOUND"
    echo "See details in: $VERIFY_LOG"
    VERIFY_STATUS="FAILED"
    
    if [ $MISSING_COUNT -gt 0 ]; then
        echo "  → $MISSING_COUNT files missing from destination"
    fi
    if [ $CORRUPTED_COUNT -gt 0 ]; then
        echo "  → $CORRUPTED_COUNT files corrupted (hash mismatch)"
    fi
    if [ $EXTRA_COUNT -gt 0 ]; then
        echo "  → $EXTRA_COUNT extra files in destination"
    fi
fi

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║              STEP 3 COMPLETE                   ║"
echo "╚════════════════════════════════════════════════╝"
echo "Verification Status: $VERIFY_STATUS"
echo "Perfect matches: $MATCH_COUNT files"
[ $MISSING_COUNT -gt 0 ] && echo "Missing: $MISSING_COUNT files"
[ $CORRUPTED_COUNT -gt 0 ] && echo "Corrupted: $CORRUPTED_COUNT files"
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
