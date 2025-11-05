#!/bin/bash

# UPS Monitor for Safe Copy Operations
# Monitors UPS battery level and shuts down operations when power is low

# Configuration
UPS_ID="-1500"
LOW_BATTERY_THRESHOLD=30  # Stop operations at 30% battery
CRITICAL_BATTERY_THRESHOLD=15  # Force unmount at 15% battery
CHECK_INTERVAL=30  # Check every 30 seconds
LOG_FILE="/tmp/ups_monitor.log"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to get UPS battery percentage
get_ups_battery() {
    local battery_info=$(pmset -g batt | grep -F -- "$UPS_ID")
    if [ -n "$battery_info" ]; then
        # Extract percentage from: -1500 (id=-96796672) 100%; charging present: true
        echo "$battery_info" | grep -o '[0-9]\+%;' | cut -d'%' -f1
    else
        echo "0"
    fi
}

# Function to get UPS power source
get_ups_power_source() {
    local power_info=$(pmset -g batt | grep -F -- "$UPS_ID")
    if [ -n "$power_info" ]; then
        if echo "$power_info" | grep -q "charging present: true"; then
            echo "AC"
        else
            echo "Battery"
        fi
    else
        echo "Unknown"
    fi
}

# Function to check if UPS is present
is_ups_present() {
    pmset -g batt | grep -qF -- "$UPS_ID"
}

# Function to send notification
send_notification() {
    local title="$1"
    local message="$2"
    
    # Try to send macOS notification
    if command -v osascript &> /dev/null; then
        osascript -e "display notification \"$message\" with title \"$title\" subtitle \"UPS Monitor\""
    fi
    
    # Also try to play a sound (if available)
    if command -v afplay &> /dev/null; then
        afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || true
    fi
}

# Function to safely stop operations
stop_operations() {
    local reason="$1"
    
    log "⚠️  $reason - Stopping all copy operations..."
    
    # Send notification
    send_notification "UPS Alert" "$reason - Stopping operations"
    
    # Find and kill safe-copy processes
    local pids=$(pgrep -f "step[12]-copy.sh\|step2-hash.sh" 2>/dev/null || true)
    
    if [ -n "$pids" ]; then
        log "Terminating processes: $pids"
        echo "$pids" | xargs kill -TERM 2>/dev/null || true
        
        # Wait a bit for graceful shutdown
        sleep 5
        
        # Force kill if still running
        local remaining_pids=$(pgrep -f "step[12]-copy.sh\|step2-hash.sh" 2>/dev/null || true)
        if [ -n "$remaining_pids" ]; then
            log "Force killing remaining processes: $remaining_pids"
            echo "$remaining_pids" | xargs kill -KILL 2>/dev/null || true
        fi
    fi
    
    # Create shutdown flag file for other scripts to check
    touch "/tmp/ups_emergency_shutdown"
    
    log "✅ Operations stopped due to UPS power condition"
}

# Function to unmount drives (critical battery)
unmount_drives() {
    log "🚨 CRITICAL: Unmounting all external drives!"
    
    send_notification "CRITICAL UPS Alert" "Unmounting drives - Battery critically low!"
    
    # Get list of external volumes (excluding system volumes)
    local volumes=$(diskutil list external | grep "/dev/disk" | awk '{print $1}' | sort -u)
    
    for volume in $volumes; do
        log "Attempting to unmount $volume"
        diskutil unmountDisk "$volume" 2>/dev/null || {
            log "Failed to unmount $volume, trying force unmount"
            diskutil unmountDisk force "$volume" 2>/dev/null || true
        }
    done
    
    log "✅ Drive unmount completed"
}

# Main monitoring function
monitor_ups() {
    log "🔋 UPS Monitor started - Monitoring $UPS_ID"
    log "Thresholds: Low=$LOW_BATTERY_THRESHOLD%, Critical=$CRITICAL_BATTERY_THRESHOLD%"
    
    while true; do
        # Check if UPS is still present
        if ! is_ups_present; then
            log "⚠️  UPS no longer detected - stopping monitor"
            break
        fi
        
        local battery=$(get_ups_battery)
        local power_source=$(get_ups_power_source)
        
        log "UPS Status: $battery% ($power_source)"
        
        # Check if on battery power
        if [ "$power_source" = "Battery" ]; then
            if [ "$battery" -le "$CRITICAL_BATTERY_THRESHOLD" ]; then
                log "🚨 CRITICAL BATTERY LEVEL: $battery%"
                unmount_drives
                break
            elif [ "$battery" -le "$LOW_BATTERY_THRESHOLD" ]; then
                log "⚠️  LOW BATTERY LEVEL: $battery%"
                stop_operations "Low battery ($battery%)"
                break
            fi
        fi
        
        sleep $CHECK_INTERVAL
    done
    
    log "UPS Monitor stopped"
}

# Handle signals
trap 'log "UPS Monitor interrupted"; exit 0' INT TERM

# Start monitoring
if [ "$1" = "--test" ]; then
    log "🧪 Test mode - simulating low battery"
    stop_operations "Test - Simulated low battery"
    exit 0
fi

monitor_ups
