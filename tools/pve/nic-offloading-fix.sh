#!/usr/bin/env bash

# Creates a systemd service to disable NIC offloading for Intel e1000/e1000e and Realtek r8169 interfaces
# Author: rcastley
# License: MIT

YW=$(echo "\033[33m")
YWB=$'\e[93m'
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
TAB="  "
CM="${TAB}✔️${TAB}"
CROSS="${TAB}✖️${TAB}"
INFO="${TAB}ℹ️${TAB}${CL}"
WARN="${TAB}⚠️${TAB}${CL}"

function header_info {
  clear
  cat <<"EOF"

    _   ____________   ____  __________                ___                ____  _            __    __
   / | / /  _/ ____/  / __ \/ __/ __/ /___  ____ _____/ (_)___  ____ _   / __ \(_)________ _/ /_  / /__  _____
  /  |/ // // /      / / / / /_/ /_/ / __ \/ __ `/ __  / / __ \/ __ `/  / / / / / ___/ __ `/ __ \/ / _ \/ ___/
 / /|  // // /___   / /_/ / __/ __/ / /_/ / /_/ / /_/ / / / / / /_/ /  / /_/ / (__  ) /_/ / /_/ / /  __/ /
/_/ |_/___/\____/   \____/_/ /_/ /_/\____/\__,_/\__,_/_/_/ /_/\__, /  /_____/_/____/\__,_/_.___/_/\___/_/
                                                             /____/
Supports Intel e1000/e1000e and Realtek r8169

EOF
}

# Telemetry
source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/api/api.func") 2>/dev/null || true
declare -f init_tool_telemetry &>/dev/null && init_tool_telemetry "nic-offloading-fix" "pve"

header_info

function msg_info() { echo -e "${INFO} ${YW}${1}...${CL}"; }
function msg_ok() { echo -e "${CM} ${GN}${1}${CL}"; }
function msg_error() { echo -e "${CROSS} ${RD}${1}${CL}"; }
function msg_warn() { echo -e "${WARN} ${YWB}${1}"; }

function nic_vendor() {
  case "$1" in
    e1000 | e1000e) printf '%s\n' "Intel" ;;
    r8169) printf '%s\n' "Realtek" ;;
    *) printf '%s\n' "Unknown" ;;
  esac
}

function nic_supported() {
  case "$1" in
    e1000 | e1000e | r8169) return 0 ;;
    *) return 1 ;;
  esac
}

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
  msg_error "Error: This script must be run as root."
  exit 104
fi

if ! command -v ethtool >/dev/null 2>&1; then
  msg_info "Installing ethtool"
  apt-get update &>/dev/null
  apt-get install -y ethtool &>/dev/null || {
    msg_error "Failed to install ethtool. Exiting."
    exit 237
  }
  msg_ok "ethtool installed successfully"
fi

# Get list of network interfaces using Intel e1000/e1000e or Realtek r8169
INTERFACES=()
COUNT=0

msg_info "Searching for Intel e1000/e1000e and Realtek r8169 interfaces"

for device in /sys/class/net/*; do
  interface="$(basename "$device")" # or adjust the rest of the usages below, as mostly you'll use the path anyway
  # Skip loopback interface and virtual interfaces
  if [[ "$interface" != "lo" ]] && [[ ! "$interface" =~ ^(tap|fwbr|veth|vmbr|bonding_masters) ]]; then
    driver=$(basename "$(readlink -f "/sys/class/net/$interface/device/driver" 2>/dev/null)" 2>/dev/null)

    if nic_supported "$driver"; then
      # Get MAC address for additional identification
      mac=$(cat "/sys/class/net/$interface/address" 2>/dev/null)
      INTERFACES+=("$interface" "$(nic_vendor "$driver") $driver NIC ($mac)")
      COUNT=$((COUNT + 1))
    fi
  fi
done

# Check if any supported interfaces were found
if [ ${#INTERFACES[@]} -eq 0 ]; then
  whiptail --title "Error" --msgbox "No Intel e1000/e1000e or Realtek r8169 network interfaces found!" 10 70
  msg_error "No Intel e1000/e1000e or Realtek r8169 network interfaces found! Exiting."
  exit 236
fi

msg_ok "Found ${BL}$COUNT${GN} Intel or Realtek interfaces"

# Leave a blank screen behind the dialogs. Whiptail shows that screen for
# a frame whenever a box closes, and status text there reads as a flash.
clear >/dev/tty 2>/dev/null || clear

# Create a checklist for interface selection with all interfaces initially checked
INTERFACES_CHECKLIST=()
for ((i = 0; i < ${#INTERFACES[@]}; i += 2)); do
  INTERFACES_CHECKLIST+=("${INTERFACES[i]}" "${INTERFACES[i + 1]}" "ON")
done

# Show interface selection checklist
SELECTED_INTERFACES=$(whiptail --backtitle "NIC Offloading Disabler" --title "Network Interfaces" \
  --separate-output --checklist "Select Intel or Realtek network interfaces\n(Space to toggle, Enter to confirm):" 15 90 6 \
  "${INTERFACES_CHECKLIST[@]}" 3>&1 1>&2 2>&3)

exitstatus=$?
if [ $exitstatus != 0 ]; then
  msg_info "User canceled. Exiting."
  exit 0
fi

# Check if any interfaces were selected
if [ -z "$SELECTED_INTERFACES" ]; then
  msg_error "No interfaces selected. Exiting."
  exit 0
fi

# Convert the selected interfaces into an array
readarray -t INTERFACE_ARRAY <<<"$SELECTED_INTERFACES"

# Ask for confirmation with the list of selected interfaces
CONFIRMATION_MSG="You have selected the following interface(s):\n\n"
for iface in "${INTERFACE_ARRAY[@]}"; do
  SPEED=$(cat /sys/class/net/$iface/speed 2>/dev/null || echo "Unknown")
  MAC=$(cat /sys/class/net/$iface/address 2>/dev/null)
  DRIVER=$(basename "$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null)" 2>/dev/null)
  CONFIRMATION_MSG+="- $iface (Driver: $(nic_vendor "$DRIVER") $DRIVER, MAC: $MAC, Speed: ${SPEED}Mbps)\n"
done
CONFIRMATION_MSG+="\nThis will create systemd service(s) to disable offloading features.\n\nProceed?"

if ! whiptail --backtitle "NIC Offloading Disabler" --title "Confirmation" \
  --yesno "$CONFIRMATION_MSG" 20 80; then
  msg_info "User canceled. Exiting."
  exit 0
fi

# No progress dialog here. A gauge redraws 0% then 100% in one frame and
# flashes through the confirmation box. Apply quietly, then show the summary.
for SELECTED_INTERFACE in "${INTERFACE_ARRAY[@]}"; do
  DRIVER=$(basename "$(readlink -f "/sys/class/net/$SELECTED_INTERFACE/device/driver" 2>/dev/null)" 2>/dev/null)
  VENDOR=$(nic_vendor "$DRIVER")
  SERVICE_NAME="disable-nic-offload-$SELECTED_INTERFACE.service"
  SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

  cat >"$SERVICE_PATH" <<EOF
[Unit]
Description=Disable NIC offloading for $VENDOR $DRIVER interface $SELECTED_INTERFACE
After=network.target

[Service]
Type=oneshot
# Disable offloading features for $VENDOR $DRIVER
ExecStart=/sbin/ethtool -K $SELECTED_INTERFACE gso off gro off tso off tx off rx off rxvlan off txvlan off sg off
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null 2>&1
  systemctl start "$SERVICE_NAME" >/dev/null 2>&1
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
done

# Prepare summary of all interfaces
SUMMARY_MSG="Services created successfully!\n\n"
SUMMARY_MSG+="Configured Interfaces:\n"

for iface in "${INTERFACE_ARRAY[@]}"; do
  SERVICE_NAME="disable-nic-offload-$iface.service"
  DRIVER=$(basename "$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null)" 2>/dev/null)

  if systemctl is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1; then
    SVC_STATUS="Active"
  else
    SVC_STATUS="Inactive"
  fi

  if systemctl is-enabled --quiet "$SERVICE_NAME" >/dev/null 2>&1; then
    BOOT_SVC_STATUS="Enabled"
  else
    BOOT_SVC_STATUS="Disabled"
  fi

  SUMMARY_MSG+="- $iface ($(nic_vendor "$DRIVER") $DRIVER): $SVC_STATUS, Boot: $BOOT_SVC_STATUS\n"
done

# Show summary results
whiptail --backtitle "NIC Offloading Disabler" --title "Success" --msgbox "$SUMMARY_MSG" 22 80

msg_ok "NIC offloading disabled for ${#INTERFACE_ARRAY[@]} interface(s)!"

# Show verification commands
echo ""
msg_info "Verification commands:"
for iface in "${INTERFACE_ARRAY[@]}"; do
  echo -e "${TAB}${BL}ethtool -k $iface${CL} ${YW}# Check offloading status${CL}"
  echo -e "${TAB}${BL}systemctl status disable-nic-offload-$iface.service${CL} ${YW}# Check service status${CL}"
done

exit 0
