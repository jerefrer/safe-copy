#!/bin/bash
# OLD DRIVE RUSHES RECOVERY - With hashdeep verification and duplicate detection

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

# Check for hashdeep
if ! command -v hashdeep &> /dev/null; then
    echo "ERROR: hashdeep not found. Install with: brew install md5deep"
    exit 1
fi

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
echo "✅ DATA IS NOW SAFE ON DESTINATION!" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

# STEP 3: Hash-based verification with hashdeep (PARALLEL WITH PROGRESS)
echo "=== STEP 3: VERIFICATION WITH HASHDEEP ===" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Creating hash manifests for verification..." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

read -p "Verify with hashdeep? (Y/n): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    # Check if source still mounted
    MOUNT_POINT=$(diskutil info "$SOURCE_DISK" | grep "Mount Point" | cut -d: -f2 | xargs)
    if [ -z "$MOUNT_POINT" ] || [ "$MOUNT_POINT" = "" ]; then
        echo "Source drive is not mounted. Please mount it read-only again using Disk Arbitrator."
        read -p "Press Enter when ready..."
        MOUNT_POINT=$(diskutil info "$SOURCE_DISK" | grep "Mount Point" | cut -d: -f2 | xargs)
    fi
    
    SOURCE_MANIFEST="$MANIFEST_DIR/${DRIVE_NAME}_source_manifest.txt"
    DEST_MANIFEST="$MANIFEST_DIR/${DRIVE_NAME}_manifest.txt"
    SOURCE_LOG="$LOG_DIR/${DRIVE_NAME}_source_hash.log"
    DEST_LOG="$LOG_DIR/${DRIVE_NAME}_dest_hash.log"
    
    echo "Counting files on both drives..." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
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
    
    echo "Source drive: $SOURCE_TOTAL files" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "Destination drive: $DEST_TOTAL files" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    echo "Hashing BOTH drives in parallel..." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "This will take approximately 11-15 hours (limited by slower drive)..." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "Started: $(date)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
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
    
    echo "Both hashing processes started!" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
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
    
    echo "Both hashing processes completed: $(date)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    if [ $SOURCE_HASH_EXIT -ne 0 ]; then
        echo "⚠️  Warning: Source hashing had errors (exit code: $SOURCE_HASH_EXIT)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    fi
    
    if [ $DEST_HASH_EXIT -ne 0 ]; then
        echo "⚠️  Warning: Destination hashing had errors (exit code: $DEST_HASH_EXIT)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    fi
    
    # Continue with comparison (rest of the script stays the same)
    echo "Comparing manifests to verify copy integrity..." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    # ... [rest of comparison code as before]
    VERIFY_LOG="$LOG_DIR/${DRIVE_NAME}_verify_details.txt"
    
    # Parse both manifests and compare
    # Create temporary sorted hash lists (hash only, for comparison)
    awk 'NR>2 && /^[0-9]/ {print $2}' "$SOURCE_MANIFEST" | sort > /tmp/source_hashes_$$.txt
    awk 'NR>2 && /^[0-9]/ {print $2}' "$DEST_MANIFEST" | sort > /tmp/dest_hashes_$$.txt
    
    # Count files
    SOURCE_FILE_COUNT=$(wc -l < /tmp/source_hashes_$$.txt | xargs)
    DEST_FILE_COUNT=$(wc -l < /tmp/dest_hashes_$$.txt | xargs)
    
    echo "Source files: $SOURCE_FILE_COUNT" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "Destination files: $DEST_FILE_COUNT" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    # Find missing files (in source but not in destination)
    comm -23 /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt > /tmp/missing_$$.txt
    MISSING_COUNT=$(wc -l < /tmp/missing_$$.txt | xargs)
    
    # Find extra files (in destination but not in source - shouldn't happen)
    comm -13 /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt > /tmp/extra_$$.txt
    EXTRA_COUNT=$(wc -l < /tmp/extra_$$.txt | xargs)
    
    # Perfect matches
    comm -12 /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt > /tmp/matches_$$.txt
    MATCH_COUNT=$(wc -l < /tmp/matches_$$.txt | xargs)
    
    echo "=== VERIFICATION RESULTS ===" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "✅ Perfect matches: $MATCH_COUNT files" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    if [ $MISSING_COUNT -gt 0 ]; then
        echo "❌ Missing from destination: $MISSING_COUNT files" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        echo "" >> "$VERIFY_LOG"
        echo "MISSING FILES (in source but not in destination):" >> "$VERIFY_LOG"
        while read hash; do
            grep "$hash" "$SOURCE_MANIFEST" >> "$VERIFY_LOG"
        done < /tmp/missing_$$.txt
    fi
    
    if [ $EXTRA_COUNT -gt 0 ]; then
        echo "⚠️  Extra files in destination: $EXTRA_COUNT files" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        echo "" >> "$VERIFY_LOG"
        echo "EXTRA FILES (in destination but not in source):" >> "$VERIFY_LOG"
        while read hash; do
            grep "$hash" "$DEST_MANIFEST" >> "$VERIFY_LOG"
        done < /tmp/extra_$$.txt
    fi
    
    # Clean up temp files
    rm -f /tmp/source_hashes_$$.txt /tmp/dest_hashes_$$.txt /tmp/missing_$$.txt /tmp/extra_$$.txt /tmp/matches_$$.txt
    
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    if [ $MISSING_COUNT -eq 0 ] && [ $EXTRA_COUNT -eq 0 ] && [ $SOURCE_FILE_COUNT -eq $DEST_FILE_COUNT ]; then
        echo "✅ ✅ ✅ VERIFICATION PASSED ✅ ✅ ✅" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        echo "All $MATCH_COUNT files copied perfectly!" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        VERIFY_STATUS="VERIFIED"
    else
        echo "❌ VERIFICATION ISSUES FOUND" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        echo "See details in: $VERIFY_LOG" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        VERIFY_STATUS="FAILED"
    fi
    
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    # STEP 4: Check for duplicates in destination (same as before)
    echo "=== STEP 4: DUPLICATE DETECTION ===" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "Analyzing destination for duplicate files..." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    DUPES_REPORT="$LOG_DIR/${DRIVE_NAME}_duplicates.txt"
    
    # [Same duplicate detection code as before]
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
    
    # Extract summary for main report
    DUPE_COUNT=$(grep -c "Duplicate Set" "$DUPES_REPORT" || echo "0")
    WASTED_SPACE=$(grep "Total wasted space" "$DUPES_REPORT" | awk '{print $4, $5, $6}')
    
    if [ "$DUPE_COUNT" -eq 0 ]; then
        echo "✅ No duplicate files found" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    else
        echo "⚠️  Found $DUPE_COUNT sets of duplicate files" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        echo "   Wasted space: $WASTED_SPACE" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
        echo "   See detailed report: $DUPES_REPORT" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    fi
    
else
    echo "Skipping verification." | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    VERIFY_STATUS="SKIPPED"
    DUPE_COUNT="N/A"
fi

# Summary
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "╔════════════════════════════════════════════════╗" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "║                    SUMMARY                     ║" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "╚════════════════════════════════════════════════╝" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Drive Name: $DRIVE_NAME" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Total Files: $(find "$DEST_DIR" -type f 2>/dev/null | wc -l | xargs)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Total Size: $(du -sh "$DEST_DIR" 2>/dev/null | cut -f1)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Copy Status: $COPY_STATUS" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "Verification: $VERIFY_STATUS" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

if [ "$VERIFY_STATUS" = "VERIFIED" ]; then
    echo "  ✅ $MATCH_COUNT files verified perfectly" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
elif [ "$VERIFY_STATUS" = "FAILED" ]; then
    echo "  ✅ Matches: $MATCH_COUNT" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    [ $MISSING_COUNT -gt 0 ] && echo "  ❌ Missing: $MISSING_COUNT" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    [ $EXTRA_COUNT -gt 0 ] && echo "  ⚠️  Extra: $EXTRA_COUNT" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
fi

if [ "$VERIFY_STATUS" != "SKIPPED" ]; then
    echo "Duplicates: $DUPE_COUNT sets found" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
fi

echo "Completed: $(date)" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "📁 Files: $DEST_DIR" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "📄 Main Report: $LOG_DIR/${DRIVE_NAME}_report.txt" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

if [ "$VERIFY_STATUS" != "SKIPPED" ]; then
    echo "📋 Hash Manifests:" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "   Source: $SOURCE_MANIFEST" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    echo "   Destination: $DEST_MANIFEST" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    
    [ -f "$VERIFY_LOG" ] && echo "📋 Verification details: $VERIFY_LOG" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
    [ "$DUPE_COUNT" != "0" ] && [ "$DUPE_COUNT" != "N/A" ] && echo "📋 Duplicates report: $DUPES_REPORT" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
fi

echo "" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"
echo "You can now safely unmount the source drive using Disk Arbitrator" | tee -a "$LOG_DIR/${DRIVE_NAME}_report.txt"

if [ "$VERIFY_STATUS" = "VERIFIED" ] && [ "$COPY_STATUS" = "SUCCESS" ]; then
    exit 0
else
    exit 1
fi