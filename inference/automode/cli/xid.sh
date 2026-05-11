#!/bin/bash
#
# Inject XID and SXID errors into dmesg for testing monitoring systems
#
# This script writes formatted error messages directly to /dev/kmsg
# which will appear in dmesg output, allowing you to test if monitoring
# systems detect GPU and NVSwitch errors.
#
# Usage:
#   sudo ./inject-xid-errors.sh [xid|sxid|both] [xid_code] [gpu_id]
#
# Examples:
#   sudo ./inject-xid-errors.sh xid 13 0          # Inject XID 13 for GPU 0
#   sudo ./inject-xid-errors.sh sxid 1            # Inject SXID 1
#   sudo ./inject-xid-errors.sh both              # Inject both (default XID 13, SXID 1)
#

set -euo pipefail

# Default values
ERROR_TYPE="${1:-both}"
XID_CODE="${2:-13}"
SXID_CODE="${3:-1}"
GPU_ID="${4:-0}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
    echo "Reason: Writing to /dev/kmsg requires root privileges"
    exit 1
fi

# Check if /dev/kmsg exists
if [ ! -w /dev/kmsg ]; then
    echo -e "${RED}Error: Cannot write to /dev/kmsg${NC}"
    exit 1
fi

# Function to inject XID error
inject_xid() {
    local xid_code=$1
    local gpu_id=$2
    local pci_addr="0000:DB:00.0"  # Typical B200 PCI address format
    
    # Get current timestamp
    local timestamp=$(date +"%s")
    
    # XID error format: NVRM: Xid (PCI:0000:XX:XX.X): YY, ...
    # Common XID codes from monitoring-notes.sh:
    # 13  = Graphics engine exception
    # 31  = GPU memory page fault
    # 32  = Invalid or corrupted push buffer stream
    # 43  = GPU stopped responding / GPU hang detected
    # 48  = Double bit ECC error (uncorrectable memory corruption)
    # 63  = Microcontroller halt / Row remapper failure
    # 64  = Row remapper full (serious)
    # 74  = NVLink error
    # 79  = GPU has fallen off the bus
    # 119 = GPU thermal shutdown (overheating)
    # 120 = Power supply issue
    # 145 = RLW_SRC_TRACK errors - NVSwitch tray power cycle issue (GB200 NVL72)
    # 149 = Hardware reliability issue - backplane connector durability (GB200 NVL72)
    
    local xid_message="NVRM: Xid (PCI:${pci_addr}): ${xid_code}, Graphics Engine Exception on GPU ${gpu_id}"
    
    # Write to kernel message buffer
    # Format: <priority>timestamp;message
    # Priority 3 = KERN_ERR (error level)
    # Note: The kernel will add its own prefix, so we just need the message
    echo "<3>${xid_message}" > /dev/kmsg
    
    echo -e "${GREEN}✓ Injected XID ${xid_code} error for GPU ${gpu_id}${NC}"
    echo "  Message: ${xid_message}"
}

# Function to inject SXID error
inject_sxid() {
    local sxid_code=$1
    local nvswitch_id="${2:-0}"
    
    # Get current timestamp
    local timestamp=$(date +"%s")
    
    # SXID error format: nvidia-nvswitch nvswitchX: SXid YY, ...
    local sxid_message="nvidia-nvswitch nvswitch${nvswitch_id}: SXid ${sxid_code}, NVSwitch error detected on switch ${nvswitch_id}"
    
    # Write to kernel message buffer
    # Priority 3 = KERN_ERR (error level)
    # Note: The kernel will add its own prefix, so we just need the message
    echo "<3>${sxid_message}" > /dev/kmsg
    
    echo -e "${GREEN}✓ Injected SXID ${sxid_code} error for NVSwitch ${nvswitch_id}${NC}"
    echo "  Message: ${sxid_message}"
}

# Main execution
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}GPU Error Injection Tool${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo "This will inject errors into the kernel log buffer (/dev/kmsg)"
echo "These errors will appear in dmesg and should be detected by monitoring systems"
echo ""
echo "Configuration:"
echo "  Error type: ${ERROR_TYPE}"
echo "  XID code: ${XID_CODE}"
echo "  SXID code: ${SXID_CODE}"
echo "  GPU ID: ${GPU_ID}"
echo ""

# Inject errors based on type
case "${ERROR_TYPE}" in
    xid)
        inject_xid "${XID_CODE}" "${GPU_ID}"
        ;;
    sxid)
        inject_sxid "${SXID_CODE}" "${GPU_ID}"
        ;;
    both)
        inject_xid "${XID_CODE}" "${GPU_ID}"
        echo ""
        inject_sxid "${SXID_CODE}" "${GPU_ID}"
        ;;
    *)
        echo -e "${RED}Error: Invalid error type '${ERROR_TYPE}'${NC}"
        echo "Valid options: xid, sxid, both"
        exit 1
        ;;
esac

echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${GREEN}Error injection complete!${NC}"
echo ""
echo "Verify the errors were injected:"
echo "  sudo dmesg | grep -i 'xid\|sxid' | tail -5"
echo "  sudo dmesg -T | tail -20"
echo ""
echo "Check if monitoring systems detected them:"
echo "  journalctl -k | grep -i 'xid\|sxid'"
echo -e "${YELLOW}========================================${NC}"