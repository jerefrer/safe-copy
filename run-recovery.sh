#!/bin/bash
# MASTER SCRIPT: Interactive Drive Recovery Workflow
# Guides you through the recovery process step by step

# Color codes for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_header() {
    echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║$1${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Function to read with timeout (auto-continue after 10 seconds)
# Usage: read_with_timeout "prompt" "default_value" timeout_seconds
read_with_timeout() {
    local prompt="$1"
    local default="$2"
    local timeout="${3:-10}"
    
    echo -n "$prompt"
    
    # Read with timeout
    if read -t "$timeout" -n 1 -r REPLY; then
        echo ""
        return 0
    else
        # Timeout - use default
        REPLY="$default"
        echo ""
        echo "(Auto-continuing with default after ${timeout}s)"
        return 0
    fi
}

# Function to check if a step was completed
check_step_completed() {
    local step=$1
    local drive_name=$2
    local dest_base=$3
    local source_disk=$4
    
    case $step in
        1)
            # Check if destination directory exists and has files
            if [ -d "$dest_base/video_rushes/$drive_name" ] && [ "$(find "$dest_base/video_rushes/$drive_name" -type f 2>/dev/null | head -n 1)" ]; then
                return 0
            fi
            ;;
        2)
            # Check if manifests exist AND hashing is complete
            local source_manifest="$dest_base/_manifests/${drive_name}_source_manifest.txt"
            local dest_manifest="$dest_base/_manifests/${drive_name}_manifest.txt"
            local source_state="$dest_base/_manifests/${drive_name}_source_state.txt"
            local dest_state="$dest_base/_manifests/${drive_name}_dest_state.txt"
            
            if [ -f "$source_manifest" ] && [ -f "$dest_manifest" ] && [ -f "$source_state" ] && [ -f "$dest_state" ]; then
                # Count hashed files from state files
                local source_hashed=$(wc -l < "$source_state" 2>/dev/null | xargs)
                local dest_hashed=$(wc -l < "$dest_state" 2>/dev/null | xargs)
                
                # Count data lines in manifests (excluding headers)
                local source_manifest_lines=$(grep -c '^[0-9]' "$source_manifest" 2>/dev/null || echo "0")
                local dest_manifest_lines=$(grep -c '^[0-9]' "$dest_manifest" 2>/dev/null || echo "0")
                
                # Consider complete if state files match manifest line counts and both have content
                if [ "$source_hashed" -eq "$source_manifest_lines" ] && [ "$dest_hashed" -eq "$dest_manifest_lines" ] && [ "$source_hashed" -gt 0 ] && [ "$dest_hashed" -gt 0 ]; then
                    return 0
                fi
            fi
            ;;
        3)
            # Check if verification log exists
            if [ -f "$dest_base/_logs/${drive_name}_verify_details.txt" ] || grep -q "VERIFICATION" "$dest_base/_logs/${drive_name}_report.txt" 2>/dev/null; then
                return 0
            fi
            ;;
        4)
            # Check if duplicates report exists
            if [ -f "$dest_base/_logs/${drive_name}_duplicates.txt" ]; then
                return 0
            fi
            ;;
    esac
    return 1
}

# Main script
clear
print_header "      DRIVE RECOVERY - INTERACTIVE WORKFLOW      "
echo ""
echo "This script will guide you through the recovery process:"
echo "  Step 1: Copy files from source to destination"
echo "  Step 2: Hash both drives for verification"
echo "  Step 3: Verify copy integrity"
echo "  Step 4: Detect duplicate files"
echo ""

# Get parameters from command line or prompt interactively
if [ "$#" -eq 3 ]; then
    # Use command line arguments
    SOURCE_DISK=$1
    DRIVE_NAME=$2
    DEST_BASE=$3
    echo "Using command line arguments:"
elif [ "$#" -eq 0 ]; then
    # Interactive mode
    read -p "Enter source disk (e.g., /dev/disk4s2): " SOURCE_DISK
    read -p "Enter drive name (e.g., \"Project_2015\"): " DRIVE_NAME
    read -p "Enter destination path (e.g., /Volumes/Exos24TB): " DEST_BASE
    echo ""
else
    print_error "Invalid number of arguments!"
    echo "Usage: $0 [source_disk] [drive_name] [destination_path]"
    echo "Example: $0 /dev/disk4s2 \"Project_2015\" /Volumes/Exos24TB"
    echo ""
    echo "Or run without arguments for interactive mode:"
    echo "  $0"
    exit 1
fi

# Validate inputs
if [ -z "$SOURCE_DISK" ] || [ -z "$DRIVE_NAME" ] || [ -z "$DEST_BASE" ]; then
    print_error "All parameters are required!"
    exit 1
fi

if [ ! -d "$DEST_BASE" ]; then
    print_error "Destination path does not exist: $DEST_BASE"
    exit 1
fi

echo "Configuration:"
echo "  Source Disk: $SOURCE_DISK"
echo "  Drive Name: $DRIVE_NAME"
echo "  Destination: $DEST_BASE"
echo ""

# Check which steps are already completed
STEP1_DONE=false
STEP2_DONE=false
STEP3_DONE=false
STEP4_DONE=false

if check_step_completed 1 "$DRIVE_NAME" "$DEST_BASE" "$SOURCE_DISK"; then
    STEP1_DONE=true
    print_success "Step 1 already completed (files exist)"
fi

if check_step_completed 2 "$DRIVE_NAME" "$DEST_BASE" "$SOURCE_DISK"; then
    STEP2_DONE=true
    print_success "Step 2 already completed (manifests exist)"
fi

if check_step_completed 3 "$DRIVE_NAME" "$DEST_BASE" "$SOURCE_DISK"; then
    STEP3_DONE=true
    print_success "Step 3 already completed (verification done)"
fi

if check_step_completed 4 "$DRIVE_NAME" "$DEST_BASE" "$SOURCE_DISK"; then
    STEP4_DONE=true
    print_success "Step 4 already completed (duplicates report exists)"
fi

echo ""
echo "════════════════════════════════════════════════"
echo ""

# Step 1: Copy
if [ "$STEP1_DONE" = true ]; then
    read_with_timeout "Step 1 already completed. Re-run? (y/N) [auto: N in 10s]: " "N" 10
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        RUN_STEP1=true
    else
        RUN_STEP1=false
    fi
else
    read_with_timeout "Run Step 1: Copy files? (Y/n) [auto: Y in 10s]: " "Y" 10
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        RUN_STEP1=true
    else
        RUN_STEP1=false
        print_warning "Skipping Step 1"
    fi
fi

if [ "$RUN_STEP1" = true ]; then
    echo ""
    print_header "           RUNNING STEP 1: COPY FILES          "
    echo ""
    sudo ./step1-copy.sh "$SOURCE_DISK" "$DRIVE_NAME" "$DEST_BASE"
    STEP1_EXIT=$?
    echo ""
    
    if [ $STEP1_EXIT -eq 0 ]; then
        STEP1_DONE=true
        print_success "Step 1 completed successfully!"
    else
        print_error "Step 1 failed or completed with errors"
        read_with_timeout "Continue anyway? (y/N) [auto: N in 10s]: " "N" 10
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    echo ""
    echo "Continuing to next step in 3 seconds..."
    sleep 3
    clear
fi

# Step 2: Hash
if [ "$STEP1_DONE" = false ]; then
    print_warning "Step 2 requires Step 1 to be completed first"
    exit 0
fi

if [ "$STEP2_DONE" = true ]; then
    read_with_timeout "Step 2 already completed. Re-run? (y/N) [auto: N in 10s]: " "N" 10
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        RUN_STEP2=true
    else
        RUN_STEP2=false
    fi
else
    read_with_timeout "Run Step 2: Hash both drives? (Y/n) [auto: Y in 10s]: " "Y" 10
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        RUN_STEP2=true
    else
        RUN_STEP2=false
        print_warning "Skipping Step 2"
    fi
fi

if [ "$RUN_STEP2" = true ]; then
    echo ""
    print_header "         RUNNING STEP 2: HASH DRIVES           "
    echo ""
    ./step2-hash.sh "$SOURCE_DISK" "$DRIVE_NAME" "$DEST_BASE"
    STEP2_EXIT=$?
    echo ""
    
    if [ $STEP2_EXIT -eq 0 ]; then
        STEP2_DONE=true
        print_success "Step 2 completed successfully!"
    else
        print_error "Step 2 failed or completed with errors"
        read_with_timeout "Continue anyway? (y/N) [auto: N in 10s]: " "N" 10
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    echo ""
    echo "Continuing to next step in 3 seconds..."
    sleep 3
    clear
fi

# Step 3: Verify
if [ "$STEP2_DONE" = false ]; then
    print_warning "Step 3 requires Step 2 to be completed first"
    exit 0
fi

if [ "$STEP3_DONE" = true ]; then
    read_with_timeout "Step 3 already completed. Re-run? (y/N) [auto: N in 10s]: " "N" 10
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        RUN_STEP3=true
    else
        RUN_STEP3=false
    fi
else
    read_with_timeout "Run Step 3: Verify copy integrity? (Y/n) [auto: Y in 10s]: " "Y" 10
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        RUN_STEP3=true
    else
        RUN_STEP3=false
        print_warning "Skipping Step 3"
    fi
fi

if [ "$RUN_STEP3" = true ]; then
    echo ""
    print_header "       RUNNING STEP 3: VERIFY INTEGRITY        "
    echo ""
    ./step3-verify.sh "$DRIVE_NAME" "$DEST_BASE"
    STEP3_EXIT=$?
    echo ""
    
    if [ $STEP3_EXIT -eq 0 ]; then
        STEP3_DONE=true
        print_success "Step 3 completed successfully!"
    else
        print_error "Step 3 failed or found verification issues"
        read_with_timeout "Continue anyway? (y/N) [auto: N in 10s]: " "N" 10
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    echo ""
    echo "Continuing to next step in 3 seconds..."
    sleep 3
    clear
fi

# Step 4: Duplicates
if [ "$STEP3_DONE" = false ] && [ "$STEP2_DONE" = false ]; then
    print_warning "Step 4 requires Step 2 to be completed first"
    exit 0
fi

if [ "$STEP4_DONE" = true ]; then
    read_with_timeout "Step 4 already completed. Re-run? (y/N) [auto: N in 10s]: " "N" 10
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        RUN_STEP4=true
    else
        RUN_STEP4=false
    fi
else
    read_with_timeout "Run Step 4: Detect duplicates? (Y/n) [auto: Y in 10s]: " "Y" 10
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        RUN_STEP4=true
    else
        RUN_STEP4=false
        print_warning "Skipping Step 4"
    fi
fi

if [ "$RUN_STEP4" = true ]; then
    echo ""
    print_header "      RUNNING STEP 4: DETECT DUPLICATES        "
    echo ""
    ./step4-duplicates.sh "$DRIVE_NAME" "$DEST_BASE"
    STEP4_EXIT=$?
    echo ""
    
    if [ $STEP4_EXIT -eq 0 ]; then
        STEP4_DONE=true
        print_success "Step 4 completed successfully!"
    else
        print_error "Step 4 failed"
    fi
    
    echo ""
fi

# Final summary
echo ""
print_header "              WORKFLOW COMPLETE                 "
echo ""
echo "Summary:"
[ "$STEP1_DONE" = true ] && print_success "Step 1: Copy files - DONE" || echo "  Step 1: Copy files - SKIPPED"
[ "$STEP2_DONE" = true ] && print_success "Step 2: Hash drives - DONE" || echo "  Step 2: Hash drives - SKIPPED"
[ "$STEP3_DONE" = true ] && print_success "Step 3: Verify integrity - DONE" || echo "  Step 3: Verify integrity - SKIPPED"
[ "$STEP4_DONE" = true ] && print_success "Step 4: Detect duplicates - DONE" || echo "  Step 4: Detect duplicates - SKIPPED"
echo ""
echo "All selected steps completed!"
echo ""
