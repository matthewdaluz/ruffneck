#!/usr/bin/env bash

# Ruffneck Hardware Scout
# Copyright (C) 2026 Matthew DaLuz
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

export SYSTEMD_PAGER=cat
export SYSTEMD_COLORS=0
export SYSTEMD_EMOJI=0
export SYSTEMD_URLIFY=0

readonly SCRIPT_TITLE="Ruffneck - Hardware/Software Scout"
readonly SCRIPT_NAME=${0##*/}
readonly RUFFNECK_VERSION="1.0.0"
readonly RUFFNECK_BUILD_DATE="September 30th, 2026."
SAVE_ENABLED=false
OUTPUT_PATH="${PWD}/ruffneck-report-$(date +%Y%m%d-%H%M%S).txt"
TEMP_REPORT=""
DISTRO_FAMILY="unknown"

declare -a MISSING_DEPENDENCIES=()
declare -a MISSING_PACKAGES=()

declare -a SECTION_KEYS=(
  system
  cpu
  memory
  motherboard
  firmware
  security
  gpu
  storage
  filesystem
  network
  audio
  usb
  sensors
  virtualization
  processes
  services
  inventory
)

declare -A SECTION_TITLES=(
  [system]="System Overview"
  [cpu]="CPU Information"
  [memory]="Memory Information"
  [motherboard]="Motherboard / Chassis"
  [firmware]="Firmware / BIOS"
  [security]="Platform Security (TPM / Secure Boot)"
  [gpu]="Graphics"
  [storage]="Storage Devices"
  [filesystem]="Filesystem Layout"
  [network]="Network & Connectivity"
  [audio]="Audio Devices"
  [usb]="USB & Peripheral Buses"
  [sensors]="Thermals & Power"
  [virtualization]="Virtualization"
  [processes]="Top Resource Consumers"
  [services]="System Services"
  [inventory]="Full Inventory (lshw/inxi)"
)

FULL_PRESET=("${SECTION_KEYS[@]}")
LITE_PRESET=(system cpu memory security storage network)

# Each entry identifies an optional diagnostic command, what it adds to a
# report, and the generic package key used by the distro-specific lookup.
declare -a OPTIONAL_DEPENDENCIES=(
  "lsb_release|distribution release details|lsb-release"
  "lscpu|CPU details|util-linux"
  "cpupower|CPU frequency details|cpupower"
  "free|memory usage|procps"
  "dmidecode|firmware and DMI tables|dmidecode"
  "fwupdmgr|firmware device details|fwupd"
  "lspci|PCI and graphics devices|pciutils"
  "glxinfo|OpenGL renderer details|mesa-utils"
  "lsblk|block device topology|util-linux"
  "smartctl|drive SMART health|smartmontools"
  "ip|network interfaces and routes|iproute"
  "nmcli|NetworkManager state|networkmanager"
  "iw|wireless interface details|iw"
  "aplay|ALSA playback devices|alsa-utils"
  "pactl|PulseAudio/PipeWire audio endpoints|pulse-utils"
  "pw-cli|PipeWire object details|pipewire-utils"
  "lsusb|USB devices|usbutils"
  "sensors|temperature and voltage sensors|lm-sensors"
  "acpi|battery and ACPI details|acpi"
  "virt-what|virtualization detection|virt-what"
  "lshw|hardware inventory|lshw"
  "inxi|extended system summary|inxi"
  "tpm2_getcap|TPM 2.0 capabilities|tpm2-tools"
  "mokutil|Secure Boot state|mokutil"
)

usage() {
  cat <<EOF
$SCRIPT_TITLE $RUFFNECK_VERSION - collect hardware and system information

Usage: $SCRIPT_NAME [--help]

Run as root without arguments to launch the interactive TUI.
EOF
}

# Return success when a command can be resolved through PATH.
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Refuse collection without full privileges. Several kernel, DMI, TPM, and
# storage interfaces otherwise return incomplete or misleading information.
require_root() {
  if (( EUID != 0 )); then
    printf 'Error: %s must be run as root.\n' "$SCRIPT_TITLE" >&2
    printf 'Run it again with sudo or from a root shell.\n' >&2
    exit 1
  fi
}

# Classify the current distribution so dependency suggestions use native
# package names and the correct package-manager syntax.
detect_distro_family() {
  local distro_id=""
  local distro_like=""
  local -a candidates=()
  local -a like_ids=()
  local candidate

  if [[ -r /etc/os-release ]]; then
    # os-release is a shell-compatible file supplied by the distribution.
    # shellcheck disable=SC1091
    . /etc/os-release
    distro_id=${ID:-}
    distro_like=${ID_LIKE:-}
  fi

  candidates+=("$distro_id")
  read -r -a like_ids <<<"$distro_like"
  candidates+=("${like_ids[@]}")

  for candidate in "${candidates[@]}"; do
    case $candidate in
      ubuntu|linuxmint|pop|neon) printf 'ubuntu\n'; return ;;
      debian) printf 'debian\n'; return ;;
      fedora|rhel|centos|rocky|almalinux|ol) printf 'fedora\n'; return ;;
      arch|manjaro|endeavouros) printf 'arch\n'; return ;;
      opensuse*|suse|sles) printf 'suse\n'; return ;;
      alpine) printf 'alpine\n'; return ;;
    esac
  done

  printf 'unknown\n'
}

# Translate generic package keys into names used by a distro family.
package_for_distro() {
  local family=$1
  local package_key=$2

  case "$family:$package_key" in
    fedora:lsb-release) printf 'lsb_release' ;;
    arch:lsb-release) printf 'lsb-release' ;;
    suse:lsb-release) printf 'lsb-release' ;;
    alpine:lsb-release) printf 'lsb-release-minimal' ;;
    ubuntu:cpupower) printf 'linux-tools-common' ;;
    debian:cpupower) printf 'linux-cpupower' ;;
    fedora:procps|arch:procps) printf 'procps-ng' ;;
    alpine:procps) printf 'procps-ng' ;;
    ubuntu:iproute|debian:iproute|arch:iproute) printf 'iproute2' ;;
    fedora:iproute) printf 'iproute' ;;
    suse:iproute) printf 'iproute2' ;;
    alpine:iproute) printf 'iproute2' ;;
    ubuntu:networkmanager|debian:networkmanager) printf 'network-manager' ;;
    fedora:networkmanager|suse:networkmanager) printf 'NetworkManager' ;;
    alpine:networkmanager) printf 'networkmanager' ;;
    fedora:mesa-utils) printf 'glx-utils' ;;
    suse:mesa-utils) printf 'Mesa-demo-x' ;;
    alpine:mesa-utils) printf 'mesa-demos' ;;
    ubuntu:pulse-utils|debian:pulse-utils) printf 'pulseaudio-utils' ;;
    fedora:pulse-utils) printf 'pulseaudio-utils' ;;
    arch:pulse-utils) printf 'libpulse' ;;
    suse:pulse-utils) printf 'libpulse-tools' ;;
    alpine:pulse-utils) printf 'pulseaudio-utils' ;;
    ubuntu:pipewire-utils|debian:pipewire-utils) printf 'pipewire-bin' ;;
    fedora:pipewire-utils) printf 'pipewire-utils' ;;
    arch:pipewire-utils) printf 'pipewire' ;;
    suse:pipewire-utils) printf 'pipewire-tools' ;;
    alpine:pipewire-utils) printf 'pipewire-tools' ;;
    fedora:lm-sensors) printf 'lm_sensors' ;;
    arch:lm-sensors) printf 'lm_sensors' ;;
    suse:lm-sensors) printf 'sensors' ;;
    alpine:lm-sensors) printf 'lm-sensors' ;;
    suse:tpm2-tools) printf 'tpm2.0-tools' ;;
    fedora:cpupower) printf 'kernel-tools' ;;
    arch:cpupower) printf 'cpupower' ;;
    suse:cpupower) printf 'cpupower' ;;
    alpine:cpupower) printf 'linux-tools' ;;
    unknown:*) printf '%s' "$package_key" ;;
    *) printf '%s' "$package_key" ;;
  esac
}

# Print one install command containing each missing package only once.
print_install_command() {
  local family=$1
  shift
  local packages=("$@")

  case $family in
    ubuntu|debian) printf '  apt install %s\n' "${packages[*]}" ;;
    fedora) printf '  dnf install %s\n' "${packages[*]}" ;;
    arch) printf '  pacman -S %s\n' "${packages[*]}" ;;
    suse) printf '  zypper install %s\n' "${packages[*]}" ;;
    alpine) printf '  apk add %s\n' "${packages[*]}" ;;
    *) printf '  Install these packages with your package manager: %s\n' "${packages[*]}" ;;
  esac
}

# Audit optional collectors once at startup and retain the results for the main
# menu. Every collector also has a fallback or an explicit unavailable state.
check_dependencies() {
  local entry command_name purpose package_key package_name
  declare -A seen_packages=()

  DISTRO_FAMILY=$(detect_distro_family)
  MISSING_DEPENDENCIES=()
  MISSING_PACKAGES=()

  for entry in "${OPTIONAL_DEPENDENCIES[@]}"; do
    IFS='|' read -r command_name purpose package_key <<<"$entry"
    if ! command_exists "$command_name"; then
      package_name=$(package_for_distro "$DISTRO_FAMILY" "$package_key")
      MISSING_DEPENDENCIES+=("$command_name|$purpose|$package_name")

      if [[ -z ${seen_packages[$package_name]+x} ]]; then
        MISSING_PACKAGES+=("$package_name")
        seen_packages[$package_name]=1
      fi
    fi
  done
}

# Display missing commands and their distro-specific packages inside the main
# menu so the information remains visible after the screen is redrawn.
display_dependency_status() {
  local entry command_name purpose package_name

  if (( ${#MISSING_DEPENDENCIES[@]} == 0 )); then
    echo "Optional tools: all detected"
    return
  fi

  printf 'Missing optional tools/packages (%d):\n' "${#MISSING_DEPENDENCIES[@]}"
  for entry in "${MISSING_DEPENDENCIES[@]}"; do
    IFS='|' read -r command_name purpose package_name <<<"$entry"
    printf '  %-14s -> %-20s %s\n' "$command_name" "$package_name" "$purpose"
  done

  printf 'Install command for %s systems:\n' "$DISTRO_FAMILY"
  print_install_command "$DISTRO_FAMILY" "${MISSING_PACKAGES[@]}"
}

header() {
  printf '\n=== %s ===\n' "$1"
}

pause_prompt() {
  if [[ -t 0 ]]; then
    read -rp "Press Enter to continue..." _ || true
  fi
}

# Remove a partially or fully generated temporary report on every exit path.
cleanup_temp_report() {
  if [[ -n $TEMP_REPORT && -f $TEMP_REPORT ]]; then
    rm -f -- "$TEMP_REPORT"
  fi
}

# Convert a user-entered leading tilde into the active user's home path.
expand_path() {
  local input=$1
  if [[ $input == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ $input == ~/* ]]; then
    printf '%s/%s\n' "$HOME" "${input#~/}"
  else
    printf '%s\n' "$input"
  fi
}

ensure_dir_writable() {
  local dir=$1

  if [ ! -d "$dir" ]; then
    if ! mkdir -p "$dir" 2>/dev/null; then
      printf 'Unable to create directory %s (insufficient permissions?)\n' "$dir"
      return 1
    fi
  fi

  if [ ! -w "$dir" ]; then
    printf 'Directory %s is not writable.\n' "$dir"
    return 1
  fi

  return 0
}

collect_section() {
  local section=$1
  local title=${SECTION_TITLES[$section]:-$section}
  local func="collect_${section}"

  header "$title"

  if declare -f "$func" >/dev/null 2>&1; then
    "$func"
  else
    echo "No collector implemented for '$section'."
  fi
}

# Turn internal section keys into a readable comma-separated report summary.
join_titles() {
  local items=("$@")
  local section
  local separator=""

  for section in "${items[@]}"; do
    printf '%s%s' "$separator" "${SECTION_TITLES[$section]:-$section}"
    separator=', '
  done
}

# Collector functions deliberately avoid changing global state. Each one emits
# plain text so the same output can be displayed and copied into a saved report.
collect_system() {
  local value

  printf 'Hostname: %s\n' "$(hostname)"
  if [[ -r /sys/class/dmi/id/sys_vendor ]]; then
    read -r value </sys/class/dmi/id/sys_vendor || value="unknown"
    printf 'Hardware vendor: %s\n' "$value"
  fi
  if [[ -r /sys/class/dmi/id/product_name ]]; then
    read -r value </sys/class/dmi/id/product_name || value="unknown"
    printf 'Hardware model: %s\n' "$value"
  fi
  if [[ -r /sys/class/dmi/id/product_version ]]; then
    read -r value </sys/class/dmi/id/product_version || value="unknown"
    printf 'Hardware version: %s\n' "$value"
  fi
  if [[ -r /sys/class/dmi/id/bios_version ]]; then
    read -r value </sys/class/dmi/id/bios_version || value="unknown"
    printf 'Firmware version: %s\n' "$value"
  fi
  if [[ -r /sys/class/dmi/id/bios_date ]]; then
    read -r value </sys/class/dmi/id/bios_date || value="unknown"
    printf 'Firmware date: %s\n' "$value"
  fi

  echo
  printf 'Kernel: %s\n' "$(uname -srmo)"
  if command_exists lsb_release; then
    lsb_release -a
  elif [ -f /etc/os-release ]; then
    echo "OS Release:"
    grep -E '^(NAME|VERSION|ID|ID_LIKE)=' /etc/os-release
  fi

  echo
  if command_exists uptime; then
    printf 'Uptime: %s\n' "$(uptime -p)"
  fi
  if command_exists who; then
    printf 'Last boot: '
    who -b
  fi
  if command_exists systemd-analyze; then
    systemd-analyze
  fi
  if command_exists timedatectl; then
    timedatectl show -p Timezone -p LocalRTC -p CanNTP -p NTPSynchronized
  fi
}

collect_cpu() {
  if command_exists lscpu; then
    lscpu
  else
    echo "/proc/cpuinfo:"
    cat /proc/cpuinfo
  fi

  echo
  printf 'Logical CPUs: %s\n' "$(nproc --all 2>/dev/null || echo "n/a")"
  if command_exists cpupower; then
    cpupower frequency-info 2>/dev/null || true
  fi
}

collect_memory() {
  if command_exists free; then
    free -h
  else
    echo "/proc/meminfo:"
    grep -E 'Mem(Total|Free|Available)|Swap(Total|Free)' /proc/meminfo
  fi

  echo
  if command_exists swapon; then
    if [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; then
      swapon --show
    else
      echo "No swap devices detected."
    fi
  else
    cat /proc/swaps
  fi

  if command_exists vmstat; then
    echo
    vmstat -s
  fi

  if command_exists dmidecode; then
    echo
    dmidecode -t memory
  fi
}

collect_motherboard() {
  if command_exists dmidecode; then
    dmidecode -t baseboard
    echo
    dmidecode -t chassis
  else
    echo "Install dmidecode to obtain motherboard information."
  fi
}

collect_firmware() {
  if command_exists dmidecode; then
    dmidecode -t bios
  else
    echo "Install dmidecode to obtain BIOS information."
  fi

  if command_exists fwupdmgr; then
    echo
    fwupdmgr get-devices
  fi
}

# Read the SecureBoot EFI variable directly when mokutil is unavailable. The
# first four bytes are EFI attributes; byte five is the enabled/disabled value.
read_secure_boot_efivar() {
  local efivar
  local state

  for efivar in /sys/firmware/efi/efivars/SecureBoot-*; do
    [[ -r $efivar ]] || continue
    state=$(od -An -t u1 -j 4 -N 1 "$efivar" 2>/dev/null)
    state=${state//[[:space:]]/}
    case $state in
      1) echo "SecureBoot enabled (read from EFI variable)." ;;
      0) echo "SecureBoot disabled (read from EFI variable)." ;;
      *) echo "SecureBoot state is unknown (unexpected EFI value: ${state:-unreadable})." ;;
    esac
    return
  done

  echo "SecureBoot state is unavailable: the EFI variable could not be read."
}

# Gather boot-chain security state and TPM device/capability information.
collect_security() {
  echo "Secure Boot:"
  if [[ -d /sys/firmware/efi ]]; then
    echo "Firmware mode: UEFI"
    if command_exists mokutil; then
      mokutil --sb-state 2>&1 || true
    else
      read_secure_boot_efivar
    fi
  else
    echo "Firmware mode: Legacy BIOS, or EFI runtime services are unavailable."
    echo "SecureBoot is not active or cannot be inspected from this environment."
  fi

  echo
  echo "Trusted Platform Module:"
  local -a tpm_devices=()
  local device
  local version

  if [[ -d /sys/class/tpm ]]; then
    shopt -s nullglob
    tpm_devices=(/sys/class/tpm/tpm*)
    shopt -u nullglob
  fi

  if (( ${#tpm_devices[@]} == 0 )); then
    echo "No TPM device was detected in /sys/class/tpm."
  else
    for device in "${tpm_devices[@]}"; do
      version="unknown"
      if [[ -r $device/tpm_version_major ]]; then
        read -r version <"$device/tpm_version_major" || version="unknown"
      fi
      printf 'Device: /dev/%s (TPM version: %s)\n' "${device##*/}" "$version"
    done
  fi

  if command_exists tpm2_getcap && (( ${#tpm_devices[@]} > 0 )); then
    echo
    echo "TPM 2.0 fixed properties:"
    tpm2_getcap properties-fixed 2>&1 || echo "Unable to query TPM 2.0 capabilities."
  elif (( ${#tpm_devices[@]} > 0 )); then
    echo "Install tpm2-tools for detailed TPM 2.0 capabilities."
  fi
}

collect_gpu() {
  if command_exists lspci; then
    echo "PCI Graphics Devices:"
    lspci -nn | grep -E 'VGA|3D|Display' || echo "No discrete VGA adapters detected."
  else
    echo "Install pciutils to inspect graphics adapters."
  fi

  if command_exists glxinfo; then
    echo
    glxinfo -B
  fi

  if command_exists nvidia-smi; then
    echo
    nvidia-smi
  fi
}

collect_storage() {
  if command_exists lsblk; then
    echo "Physical block devices:"
    lsblk -d -o NAME,MODEL,SIZE,ROTA,TYPE,TRAN,SERIAL
    echo
    echo "Logical block topology:"
    lsblk -o NAME,MODEL,SIZE,FSTYPE,TYPE,MOUNTPOINT
  else
    echo "Install util-linux to use lsblk."
  fi

  if command_exists blkid; then
    echo
    blkid
  fi

  if command_exists smartctl; then
    echo
    echo "SMART device health (smartctl -H):"
    while IFS= read -r device; do
      [ -z "$device" ] && continue
      smartctl -H "$device" 2>/dev/null || true
      echo
    done < <(smartctl --scan-open | awk '{print $1}')
  else
    echo
    echo "Install smartmontools for SMART diagnostics."
  fi
}

collect_filesystem() {
  if command_exists df; then
    df -hT
  fi

  if [ -f /etc/fstab ]; then
    echo
    echo "/etc/fstab:"
    cat /etc/fstab
  fi
}

collect_network() {
  if command_exists ip; then
    echo "Interfaces:"
    ip -brief addr
    echo
    ip -brief link
    echo
    echo "Routing table:"
    ip route show
  else
    echo "Install iproute2 to inspect interfaces."
  fi

  if command_exists nmcli; then
    echo
    nmcli device status
  fi

  if command_exists iw; then
    echo
    iw dev 2>&1
  elif command_exists iwconfig; then
    echo
    iwconfig 2>&1
  fi

  if command_exists ss; then
    echo
    echo "Active TCP/UDP sockets (top 20):"
    ss -tuna | head -n 20
  elif command_exists netstat; then
    echo
    netstat -tuna | head -n 20
  fi
}

collect_audio() {
  if command_exists aplay; then
    aplay -l
  else
    echo "Install alsa-utils to list ALSA devices."
  fi

  if command_exists pactl; then
    echo
    pactl list short sinks
    echo
    pactl list short sources
  elif command_exists pw-cli; then
    echo
    pw-cli list-objects Node
  fi
}

collect_usb() {
  if command_exists lsusb; then
    lsusb
  else
    echo "Install usbutils to list USB devices."
  fi

  if command_exists lspci; then
    echo
    echo "USB controllers:"
    lspci | grep -i usb || echo "No USB controllers reported."
  fi
}

collect_sensors() {
  if command_exists sensors; then
    sensors
  else
    echo "Install lm-sensors and run sensors-detect for thermal data."
  fi

  if command_exists acpi; then
    echo
    acpi -V
  fi
}

collect_virtualization() {
  if command_exists systemd-detect-virt; then
    systemd-detect-virt --verbose
  else
    echo "systemd-detect-virt not available."
  fi

  if command_exists virt-what; then
    echo
    virt-what
  fi

  if command_exists lscpu; then
    echo
    lscpu | grep -i virtualization
  fi
}

collect_processes() {
  echo "Top processes by memory usage:"
  if command_exists ps; then
    ps -eo pid,ppid,comm,%mem,%cpu --sort=-%mem | head -n 15
  else
    echo "ps command not available."
  fi
}

collect_services() {
  if command_exists systemctl; then
    echo "Failed services:"
    systemctl --failed
    echo
    echo "Running services (first 20):"
    systemctl list-units --type=service --state=running | head -n 22
  elif command_exists service; then
    service --status-all
  else
    echo "No service manager detected."
  fi
}

collect_inventory() {
  if command_exists lshw; then
    lshw -short || true
  else
    echo "Install lshw for a hardware inventory summary."
  fi

  echo
  if command_exists inxi; then
    inxi -Fxz
  else
    echo "Install inxi for extended system information."
  fi
}

# Run selected collectors through tee so terminal and saved output stay alike.
run_report() {
  local sections=("$@")
  if [ "${#sections[@]}" -eq 0 ]; then
    echo "No sections selected."
    return
  fi

  if ! TEMP_REPORT=$(mktemp -t ruffneck.XXXXXX); then
    echo "Unable to create a temporary report file." >&2
    return 1
  fi

  {
    printf 'Ruffneck report generated on %s\n' "$(date -Iseconds)"
    printf 'Host: %s (%s)\n' "$(hostname)" "$(uname -srmo)"
    printf 'Selected sections: %s\n' "$(join_titles "${sections[@]}")"
    printf 'Save target: %s\n' "$([[ $SAVE_ENABLED == true ]] && echo "$OUTPUT_PATH" || echo "disabled")"
    printf -- '----------------------------------------\n'

    local section
    for section in "${sections[@]}"; do
      collect_section "$section"
      echo
    done
  } | tee "$TEMP_REPORT"

  local -a pipeline_status=("${PIPESTATUS[@]}")
  if (( pipeline_status[0] != 0 || pipeline_status[1] != 0 )); then
    echo "Warning: the report could not be generated completely." >&2
  fi

  if [[ $SAVE_ENABLED == true ]]; then
    local dir
    dir=$(dirname "$OUTPUT_PATH")
    if ensure_dir_writable "$dir"; then
      if cat "$TEMP_REPORT" >"$OUTPUT_PATH"; then
        printf 'Report saved to %s\n' "$OUTPUT_PATH"
      else
        printf 'Failed to write report to %s\n' "$OUTPUT_PATH"
      fi
    else
      echo "Unable to save report because the directory is not writable."
    fi
  fi

  cleanup_temp_report
  TEMP_REPORT=""
  pause_prompt
}

# Redraw the interactive interface and show the current persistence setting.
display_banner() {
  if command_exists clear && [[ -t 1 ]] && [[ -n "${TERM:-}" ]]; then
    clear
  fi

  cat <<'EOF'
========================================
    Ruffneck - Hardware/Software Scout
========================================
EOF
  printf 'Version: %s\n' "$RUFFNECK_VERSION"
  printf 'Build date: %s\n' "$RUFFNECK_BUILD_DATE"
  printf 'Save to file: %s\n' "$([[ $SAVE_ENABLED == true ]] && echo "$OUTPUT_PATH" || echo "disabled")"
  echo
  display_dependency_status
  echo
}

configure_output() {
  echo "Current save status: $([[ $SAVE_ENABLED == true ]] && echo "enabled ($OUTPUT_PATH)" || echo "disabled")"
  read -rp "Enable saving reports to a file? (y/n): " answer || return

  case ${answer,,} in
    y|yes)
      local default_path="$OUTPUT_PATH"
      while true; do
        read -rp "Enter destination path [$default_path]: " path || return
        path=${path:-$default_path}
        path=$(expand_path "$path")
        local dir
        dir=$(dirname "$path")
        if ensure_dir_writable "$dir"; then
          OUTPUT_PATH="$path"
          SAVE_ENABLED=true
          printf 'Reports will be saved to %s\n' "$OUTPUT_PATH"
          break
        else
          echo "Please choose a different location."
        fi
      done
      ;;
    n|no)
      SAVE_ENABLED=false
      echo "Saving disabled."
      ;;
    *)
      echo "Invalid choice."
      ;;
  esac

  pause_prompt
}

# Validate section numbers, remove duplicates, and preserve the user's order.
custom_selection_menu() {
  local total=${#SECTION_KEYS[@]}
  local input
  local idx

  while true; do
    echo "Select one or more sections to collect."
    for idx in "${!SECTION_KEYS[@]}"; do
      printf ' %2d) %s\n' "$((idx + 1))" "${SECTION_TITLES[${SECTION_KEYS[$idx]}]}"
    done
    echo " all) Everything"
    echo "  q) Cancel"
    read -rp "Enter numbers separated by spaces: " input || return

    input=${input,,}
    case $input in
      "" )
        echo "No selection entered."
        continue
        ;;
      q|quit|exit)
        return
        ;;
      all)
        run_report "${FULL_PRESET[@]}"
        return
        ;;
    esac

    local token
    local -a chosen=()
    declare -A seen=()
    for token in $input; do
      if [[ $token =~ ^[0-9]+$ ]]; then
        idx=$((token - 1))
        if (( idx >= 0 && idx < total )); then
          local key=${SECTION_KEYS[$idx]}
          if [[ -z ${seen[$key]+x} ]]; then
            chosen+=("$key")
            seen[$key]=1
          fi
        fi
      fi
    done

    if [ "${#chosen[@]}" -eq 0 ]; then
      echo "No valid selections detected."
      continue
    fi

    run_report "${chosen[@]}"
    return
  done
}

main_menu() {
  while true; do
    display_banner
    echo "Welcome to Ruffneck - Hardware/Software Scout"
    cat <<EOF
[1] Preset: Full  - all sections
[2] Preset: Lite  - essentials only
[3] Custom selection
[4] Configure save-to-file settings
[5] Exit
EOF

    read -rp "Choose an option: " choice || exit 0
    case $choice in
      1)
        run_report "${FULL_PRESET[@]}"
        ;;
      2)
        run_report "${LITE_PRESET[@]}"
        ;;
      3)
        custom_selection_menu
        ;;
      4)
        configure_output
        ;;
      5)
        exit 0
        ;;
      *)
        echo "Invalid selection."
        pause_prompt
        ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  require_root
  parse_args "$@"
  check_dependencies
  main_menu
}

trap cleanup_temp_report EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
