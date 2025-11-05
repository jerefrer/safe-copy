#!/bin/bash

# Test UPS Monitoring System
# This script tests the UPS monitoring functionality

echo "🧪 Testing UPS Monitoring System"
echo "================================="

# Test 1: Check if UPS is detected
echo "Test 1: UPS Detection"
if pmset -g batt | grep -q "\-1500"; then
    echo "✅ UPS detected (-1500)"
    pmset -g batt | grep "\-1500"
else
    echo "❌ UPS not detected"
fi

echo ""

# Test 2: Test UPS monitor script directly
echo "Test 2: UPS Monitor Script"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPS_MONITOR="$SCRIPT_DIR/ups-monitor.sh"

if [ -f "$UPS_MONITOR" ] && [ -x "$UPS_MONITOR" ]; then
    echo "✅ UPS monitor script found and executable"
    
    echo "Running UPS monitor in test mode..."
    $UPS_MONITOR --test
    test_result=$?
    
    if [ $test_result -eq 0 ]; then
        echo "✅ UPS monitor test passed"
    else
        echo "❌ UPS monitor test failed"
    fi
else
    echo "❌ UPS monitor script not found or not executable"
fi

echo ""

# Test 3: Test emergency shutdown flag
echo "Test 3: Emergency Shutdown Flag"
echo "Creating emergency shutdown flag..."
touch "/tmp/ups_emergency_shutdown"

echo "Checking shutdown flag detection..."
if [ -f "/tmp/ups_emergency_shutdown" ]; then
    echo "✅ Emergency shutdown flag created"
    echo "Cleaning up test flag..."
    rm -f "/tmp/ups_emergency_shutdown"
    echo "✅ Test flag cleaned up"
else
    echo "❌ Failed to create emergency shutdown flag"
fi

echo ""

# Test 4: Show UPS status
echo "Test 4: Current UPS Status"
pmset -g batt

echo ""
echo "🎯 UPS Monitoring Test Complete"
echo ""
echo "To use UPS monitoring with your scripts:"
echo "1. Connect your UPS (Cyber Power Systems -1500)"
echo "2. Run step1-copy.sh or step2-hash.sh normally"
echo "3. UPS monitoring will start automatically"
echo "4. Operations will stop at 30% battery"
echo "5. Drives will unmount at 15% battery"
