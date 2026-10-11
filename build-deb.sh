#!/usr/bin/env bash

# Build Ruffneck as a Debian binary package.
# Copyright (C) 2026 Matthew DaLuz
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
umask 022

readonly PACKAGE_NAME="ruffneck"
readonly PACKAGE_ARCHITECTURE="all"
readonly MAINTAINER="Matthew DaLuz <matthewdaluz@matthewdaluz.me>"
readonly DEBIAN_REVISION="${RUFFNECK_DEBIAN_REVISION:-1}"
readonly SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SOURCE_SCRIPT="${SCRIPT_DIR}/ruffneck.sh"
readonly README_FILE="${SCRIPT_DIR}/README.md"
readonly LICENSE_FILE="${SCRIPT_DIR}/LICENSE"

OUTPUT_DIR="${SCRIPT_DIR}/dist"
BUILD_ROOT=""

usage() {
  cat <<EOF
Build Ruffneck as an installable Debian package.

Usage: ${0##*/} [--output-dir DIRECTORY] [--help]

Options:
  -o, --output-dir DIRECTORY  Write the package to DIRECTORY (default: dist)
  -h, --help                  Show this help text

The package version is read from RUFFNECK_VERSION in ruffneck.sh.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

cleanup() {
  if [[ -n $BUILD_ROOT && -d $BUILD_ROOT ]]; then
    rm -rf -- "$BUILD_ROOT"
  fi
}

parse_args() {
  while (( $# > 0 )); do
    case $1 in
      -o|--output-dir)
        (( $# >= 2 )) || die "$1 requires a directory."
        OUTPUT_DIR=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

# Read the application version without sourcing ruffneck.sh, which would launch
# its interactive main function.
read_version() {
  local version

  version=$(sed -n 's/^readonly RUFFNECK_VERSION="\([^"]*\)"/\1/p' "$SOURCE_SCRIPT")
  [[ -n $version ]] || die "Could not read RUFFNECK_VERSION from $SOURCE_SCRIPT."
  [[ $version =~ ^[0-9][A-Za-z0-9.+:~_-]*$ ]] || die "Invalid Debian package version: $version"

  printf '%s\n' "$version"
}

check_build_requirements() {
  local required_command

  for required_command in dpkg-deb gzip install mktemp sed; do
    command_exists "$required_command" || die "Required build command is missing: $required_command"
  done

  [[ -f $SOURCE_SCRIPT ]] || die "Source script not found: $SOURCE_SCRIPT"
  [[ -f $README_FILE ]] || die "README not found: $README_FILE"
  [[ -f $LICENSE_FILE ]] || die "License not found: $LICENSE_FILE"

  bash -n "$SOURCE_SCRIPT" || die "ruffneck.sh contains a Bash syntax error."
}

write_control_file() {
  local package_root=$1
  local version=$2

  cat >"${package_root}/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${version}
Section: utils
Priority: optional
Architecture: ${PACKAGE_ARCHITECTURE}
Maintainer: ${MAINTAINER}
Depends: bash (>= 4.0), procps
Recommends: acpi, alsa-utils, dmidecode, fwupd, inxi, iproute2, iw, linux-cpupower | linux-tools-common, lm-sensors, lsb-release, lshw, mesa-utils, mokutil, network-manager, pciutils, pipewire-bin, pulseaudio-utils, smartmontools, tpm2-tools, usbutils, virt-what
Description: Linux hardware and software diagnostic collector
 Ruffneck is an interactive Bash utility that gathers hardware, firmware,
 storage, network, security, service, and software information for debugging
 and diagnostics. It includes TPM and Secure Boot inspection and can save its
 reports as plain text.
EOF
}

write_copyright_file() {
  local package_root=$1

  cat >"${package_root}/usr/share/doc/${PACKAGE_NAME}/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Ruffneck
Source: https://github.com/matthewdaluz/ruffneck

Files: *
Copyright: 2026 Matthew DaLuz
License: GPL-3+
 This program is free software: you can redistribute it and/or modify it under
 the terms of the GNU General Public License as published by the Free Software
 Foundation, either version 3 of the License, or (at your option) any later
 version.
 .
 On Debian systems, the complete text of the GNU General Public License version
 3 is available in /usr/share/common-licenses/GPL-3.
EOF
}

write_changelog() {
  local package_root=$1
  local version=$2
  local build_timestamp

  if [[ -n ${SOURCE_DATE_EPOCH:-} ]]; then
    build_timestamp=$(date --date="@${SOURCE_DATE_EPOCH}" -R)
  else
    build_timestamp=$(date -R)
  fi

  cat >"${package_root}/usr/share/doc/${PACKAGE_NAME}/changelog.Debian" <<EOF
ruffneck (${version}) unstable; urgency=medium

  * Build Ruffneck ${version} as a Debian package.

 -- ${MAINTAINER}  ${build_timestamp}
EOF

  gzip -n -9 "${package_root}/usr/share/doc/${PACKAGE_NAME}/changelog.Debian"
}

write_man_page() {
  local package_root=$1
  local version=$2

  cat >"${package_root}/usr/share/man/man1/ruffneck.1" <<EOF
.TH RUFFNECK 1 "October 2026" "Ruffneck ${version}" "User Commands"
.SH NAME
ruffneck \- collect Linux hardware and software diagnostic information
.SH SYNOPSIS
.B sudo ruffneck
.br
.B sudo ruffneck --help
.SH DESCRIPTION
.B Ruffneck
is an interactive Bash utility that gathers hardware, firmware, storage,
network, TPM, Secure Boot, service, and software information. Ruffneck must be
run as root so protected diagnostic interfaces can be inspected consistently.
.SH OPTIONS
.TP
.BR \-h , " " \-\-help
Display usage information and exit.
.SH FILES
.TP
.I ./ruffneck-report-YYYYMMDD-HHMMSS.txt
Default report filename when report saving is enabled.
.SH AUTHOR
Matthew DaLuz
.SH LICENSE
GNU General Public License version 3 or later.
EOF

  gzip -n -9 "${package_root}/usr/share/man/man1/ruffneck.1"
}

build_package() {
  local version=$1
  local package_root
  local output_file

  BUILD_ROOT=$(mktemp -d -t ruffneck-deb.XXXXXX)
  package_root="${BUILD_ROOT}/${PACKAGE_NAME}"
  output_file="${OUTPUT_DIR}/${PACKAGE_NAME}_${version}_${PACKAGE_ARCHITECTURE}.deb"

  install -d -m 0755 \
    "${package_root}/DEBIAN" \
    "${package_root}/usr/bin" \
    "${package_root}/usr/share/doc/${PACKAGE_NAME}" \
    "${package_root}/usr/share/man/man1" \
    "$OUTPUT_DIR"

  install -m 0755 "$SOURCE_SCRIPT" "${package_root}/usr/bin/ruffneck"
  install -m 0644 "$README_FILE" "${package_root}/usr/share/doc/${PACKAGE_NAME}/README.md"
  install -m 0644 "$LICENSE_FILE" "${package_root}/usr/share/doc/${PACKAGE_NAME}/LICENSE"

  write_control_file "$package_root" "$version"
  write_copyright_file "$package_root"
  write_changelog "$package_root" "$version"
  write_man_page "$package_root" "$version"

  chmod 0755 "${package_root}/DEBIAN"
  chmod 0644 "${package_root}/DEBIAN/control"

  printf 'Building %s...\n' "$output_file"
  dpkg-deb --root-owner-group --build "$package_root" "$output_file"

  printf '\nPackage metadata:\n'
  dpkg-deb --info "$output_file"

  if command_exists lintian; then
    printf '\nRunning lintian:\n'
    if ! lintian "$output_file"; then
      printf 'lintian reported issues; the package was still created.\n' >&2
    fi
  fi

  printf '\nCreated: %s\n' "$output_file"
}

main() {
  local upstream_version
  local package_version

  parse_args "$@"
  check_build_requirements
  [[ $DEBIAN_REVISION =~ ^[A-Za-z0-9.+~]+$ ]] || die "Invalid Debian revision: $DEBIAN_REVISION"
  upstream_version=$(read_version)
  package_version="${upstream_version}-${DEBIAN_REVISION}"
  build_package "$package_version"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
