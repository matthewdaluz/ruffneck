#!/usr/bin/env bash

set -uo pipefail

export SYSTEMD_PAGER=cat

SCRIPT_NAME=${0##*/}
SAVE_ENABLED=false
OUTPUT_PATH="${PWD}/ruffneck-report-$(date +%Y%m%d-%H%M%S).txt"

declare -a SECTION_KEYS=(
  system
  cpu
  memory
  motherboard
  firmware
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
LITE_PRESET=(system cpu memory storage network)

usage() {
  cat <<EOF
ruffneck - collect hardware and system information

Usage: $SCRIPT_NAME [--help]

Run without arguments to launch the interactive TUI.
EOF
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

maybe_sudo() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    echo "Skipping '$*' (requires elevated privileges)."
    return 1
  fi
}

header() {
  printf '\n=== %s ===\n' "$1"
}

pause_prompt() {
  read -rp "Press Enter to continue..." _ || true
}

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

join_titles() {
  local items=("$@")
  local IFS=', '
  local names=()
  local section

  for section in "${items[@]}"; do
    names+=("${SECTION_TITLES[$section]:-$section}")
  done

  printf '%s' "${names[*]}"
}

collect_system() {
  if command_exists hostnamectl; then
    hostnamectl
  else
    printf 'Hostname: %s\n' "$(hostname)"
    printf 'Kernel:   %s\n' "$(uname -srmo)"
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
    swapon --show --human --color=never || echo "No swap devices detected."
  else
    cat /proc/swaps
  fi

  if command_exists vmstat; then
    echo
    vmstat -s
  fi

  if command_exists dmidecode; then
    echo
    maybe_sudo dmidecode -t memory
  fi
}

collect_motherboard() {
  if command_exists dmidecode; then
    maybe_sudo dmidecode -t baseboard
    echo
    maybe_sudo dmidecode -t chassis
  else
    echo "Install dmidecode to obtain motherboard information."
  fi
}

collect_firmware() {
  if command_exists dmidecode; then
    maybe_sudo dmidecode -t bios
  else
    echo "Install dmidecode to obtain BIOS information."
  fi

  if command_exists fwupdmgr; then
    echo
    fwupdmgr get-devices
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
      maybe_sudo smartctl -H "$device" 2>/dev/null || true
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

  if command_exists iwconfig; then
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
    maybe_sudo lshw -short || true
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

run_report() {
  local sections=("$@")
  if [ "${#sections[@]}" -eq 0 ]; then
    echo "No sections selected."
    return
  fi

  local tmp
  tmp=$(mktemp -t ruffneck.XXXXXX)

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
  } | tee "$tmp"

  if [[ $SAVE_ENABLED == true ]]; then
    local dir
    dir=$(dirname "$OUTPUT_PATH")
    if ensure_dir_writable "$dir"; then
      if cat "$tmp" >"$OUTPUT_PATH"; then
        printf 'Report saved to %s\n' "$OUTPUT_PATH"
      else
        printf 'Failed to write report to %s\n' "$OUTPUT_PATH"
      fi
    else
      echo "Unable to save report because the directory is not writable."
    fi
  fi

  rm -f "$tmp"
  pause_prompt
}

display_banner() {
  if command_exists clear && [[ -t 1 ]] && [[ -n "${TERM:-}" ]]; then
    clear
  fi

  cat <<'EOF'
========================================
        Ruffneck Hardware Scout
========================================
EOF
  printf 'Save to file: %s\n' "$([[ $SAVE_ENABLED == true ]] && echo "$OUTPUT_PATH" || echo "disabled")"
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
  parse_args "$@"
  main_menu
}

main "$@"
