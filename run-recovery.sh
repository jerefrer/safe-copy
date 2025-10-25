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

# Function to check if a step was completed
check_step_completed() {
    local step=$1
    local drive_name=$2
    local dest_base=$3
    
    case $step in
        1)
            # Check if destination directory exists and has files
            if [ -d "$dest_base/video_rushes/$drive_name" ] && [ "$(find "$dest_base/video_rushes/$drive_name" -type f 2>/dev/null | head -n 1)" ]; then
                return 0
            fi
            ;;
        2)
            # Check if manifests exist
            if [ -f "$dest_base/_manifests/${drive_name}_source_manifest.txt" ] && [ -f "$dest_base/_manifests/${drive_name}_manifest.txt" ]; then
                return 0
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

# Get parameters
read -p "Enter source disk (e.g., /dev/disk4s2): " SOURCE_DISK
read -p "Enter drive name (e.g., \"Project_2015\"): " DRIVE_NAME
read -p "Enter destination path (e.g., /Volumes/Exos24TB): " DEST_BASE

echo ""

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

if check_step_completed 1 "$DRIVE_NAME" "$DEST_BASE"; then
    STEP1_DONE=true
    print_success "Step 1 already completed (files exist)"
fi

if check_step_completed 2 "$DRIVE_NAME" "$DEST_BASE"; then
    STEP2_DONE=true
    print_success "Step 2 already completed (manifests exist)"
fi

if check_step_completed 3 "$DRIVE_NAME" "$DEST_BASE"; then
    STEP3_DONE=true
    print_success "Step 3 already completed (verification done)"
fi

if check_step_completed 4 "$DRIVE_NAME" "$DEST_BASE"; then
    STEP4_DONE=true
    print_success "Step 4 already completed (duplicates report exists)"
fi

echo ""
echo "════════════════════════════════════════════════"
echo ""

# Step 1: Copy
if [ "$STEP1_DONE" = true ]; then
    read -p "Step 1 already completed. Re-run? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        RUN_STEP1=true
    else
        RUN_STEP1=false
    fi
else
    read -p "Run Step 1: Copy files? (Y/n): " -n 1 -r
    echo ""
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
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    echo ""
    read -p "Press Enter to continue..."
    clear
fi

# Step 2: Hash
if [ "$STEP1_DONE" = false ]; then
    print_warning "Step 2 requires Step 1 to be completed first"
    exit 0
fi

if [ "$STEP2_DONE" = true ]; then
    read -p "Step 2 already completed. Re-run? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        RUN_STEP2=true
    else
        RUN_STEP2=false
    fi
else
    read -p "Run Step 2: Hash both drives? (Y/n): " -n 1 -r
    echo ""
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
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    echo ""
    read -p "Press Enter to continue..."
    clear
fi

# Step 3: Verify
if [ "$STEP2_DONE" = false ]; then
    print_warning "Step 3 requires Step 2 to be completed first"
    exit 0
fi

if [ "$STEP3_DONE" = true ]; then
    read -p "Step 3 already completed. Re-run? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        RUN_STEP3=true
    else
        RUN_STEP3=false
    fi
else
    read -p "Run Step 3: Verify copy integrity? (Y/n): " -n 1 -r
    echo ""
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
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    echo ""
    read -p "Press Enter to continue..."
    clear
fi

# Step 4: Duplicates
if [ "$STEP3_DONE" = false ] && [ "$STEP2_DONE" = false ]; then
    print_warning "Step 4 requires Step 2 to be completed first"
    exit 0
fi

if [ "$STEP4_DONE" = true ]; then
    read -p "Step 4 already completed. Re-run? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        RUN_STEP4=true
    else
        RUN_STEP4=false
    fi
else
    read -p "Run Step 4: Detect duplicates? (Y/n): " -n 1 -r
    echo ""
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
