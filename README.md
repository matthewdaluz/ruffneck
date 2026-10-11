# Ruffneck

Ruffneck is a Linux-only hardware and software information collector written in
Bash. It provides an interactive terminal interface for gathering diagnostic
details that can help troubleshoot hardware, firmware, networking, storage,
performance, and operating-system problems.

Ruffneck prints reports to the terminal and can optionally save them as plain
text files. It must be run as `root` so it can consistently access protected
interfaces such as DMI tables, storage health data, EFI variables, and TPM
devices.

## Features

- Full, lite, and custom report modes.
- Distro-aware detection of missing optional tools and their package names.
- A suggested installation command for missing diagnostic packages.
- TPM device, TPM version, and TPM 2.0 capability collection.
- UEFI and Secure Boot state detection, including an EFI-variable fallback.
- Optional timestamped text reports with a configurable destination.
- Root-only execution to prevent incomplete or misleading reports.
- Automatic temporary-file cleanup on normal exit and common termination
  signals.

## Information collected

| Section | Examples |
| --- | --- |
| System overview | Hostname, distribution, kernel, uptime, boot time, and time settings |
| CPU | Architecture, cores, virtualization flags, and frequency information |
| Memory | RAM, swap, virtual-memory statistics, and installed memory devices |
| Motherboard and chassis | Baseboard, chassis, vendor, and model information |
| Firmware | BIOS details and firmware-update devices |
| Platform security | UEFI mode, Secure Boot state, TPM devices, and TPM capabilities |
| Graphics | PCI graphics devices, OpenGL renderer, and NVIDIA status when available |
| Storage | Block-device topology, identifiers, and SMART health |
| Filesystems | Mounted filesystems and `/etc/fstab` |
| Networking | Interfaces, addresses, routes, wireless details, and active sockets |
| Audio | ALSA, PulseAudio, and PipeWire devices |
| USB and PCI buses | USB peripherals and USB controllers |
| Thermals and power | Hardware sensors, battery, and ACPI information |
| Virtualization | Hypervisor and CPU virtualization detection |
| Processes | Top processes by memory usage |
| Services | Failed and running system services |
| Inventory | Extended summaries from `lshw` and `inxi` |

The exact amount of information depends on the hardware, Linux distribution,
and optional diagnostic tools installed on the system.

## Requirements

- Linux.
- Bash 4.0 or newer.
- Root privileges.
- Standard GNU/Linux command-line utilities.

Specialized collectors are optional. Ruffneck checks for them at startup and
shows missing commands, matching package names, and an installation command in
the main menu. Package suggestions are supported for:

- Ubuntu and Ubuntu-derived distributions.
- Debian.
- Fedora, RHEL, CentOS, Rocky Linux, AlmaLinux, and Oracle Linux.
- Arch Linux, Manjaro, and EndeavourOS.
- openSUSE and SUSE Linux Enterprise.
- Alpine Linux.

## Run from source

Make the script executable and launch it with `sudo`:

```bash
chmod +x ruffneck.sh
sudo ./ruffneck.sh
```

Ruffneck deliberately applies the root requirement before processing command
line options, so help also requires elevated privileges:

```bash
sudo ./ruffneck.sh --help
```

## Report modes

The main menu provides these choices:

1. **Full** collects every available section.
2. **Lite** collects system, CPU, memory, platform security, storage, and
   networking information.
3. **Custom selection** lets you choose one or more individual sections.
4. **Configure save-to-file settings** enables or disables report saving and
   selects the destination.
5. **Exit** closes Ruffneck.

Reports are always displayed in the terminal. When saving is enabled, the
default filename is:

```text
ruffneck-report-YYYYMMDD-HHMMSS.txt
```

## Build a Debian package

The included packaging script creates an architecture-independent Debian
package. It reads the application version from `RUFFNECK_VERSION` in
`ruffneck.sh`, installs Ruffneck as `/usr/bin/ruffneck`, and includes the
README, license, Debian copyright information, changelog, and manual page.

Build the package without root privileges:

```bash
./build-deb.sh
```

The package is written to:

```text
dist/ruffneck_<version>-1_all.deb
```

Use a different output directory when needed:

```bash
./build-deb.sh --output-dir /path/to/output
```

Set a different Debian package revision through the environment:

```bash
RUFFNECK_DEBIAN_REVISION=2 ./build-deb.sh
```

The package declares core runtime requirements with `Depends` and specialized
diagnostic collectors with `Recommends`. If `lintian` is installed, the build
script runs it automatically after creating the package.

Install the generated package with APT so dependencies are resolved:

```bash
sudo apt install ./dist/ruffneck_1.0.0-1_all.deb
```

After installation, run:

```bash
sudo ruffneck
```

## Report privacy

Diagnostic reports can contain sensitive system information, including host
names, hardware serial numbers, network addresses, mounted filesystems,
processes, and service names. Review saved reports before posting them publicly
or sending them to another person.

## Author

Ruffneck is written and maintained by Matthew DaLuz.

## License

Ruffneck is free software released under the GNU General Public License version
3 or later. See [LICENSE](LICENSE) for the complete license text.
