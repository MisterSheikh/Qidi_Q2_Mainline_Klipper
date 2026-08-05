#!/usr/bin/env bash
set -Eeuo pipefail

KATAPULT_DIR="${KATAPULT_DIR:-${HOME:?HOME is not set}/katapult}"
FLASHTOOL=""
FIRMWARE=""
DEVICE=""
ASSUME_YES=0
DRY_RUN=0
EXPECTED_APPLICATION_OFFSET="0x08008000"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Flash Qidi Q2 mainboard Klipper firmware through an existing Katapult
bootloader. Katapult itself is not installed or updated by this script.

Only use this wrapper when the installed mainboard Katapult expects the
Klipper application at $EXPECTED_APPLICATION_OFFSET (32 KiB). Do not use it
with a stock, differently configured, deployer-modified, or unknown bootloader.

Options:
  --firmware PATH      Mainboard Klipper image (required)
  --device PATH        Mainboard Klipper or Katapult serial device. If omitted,
                       exactly one matching Q2 mainboard device must exist.
  --katapult-dir PATH  Katapult checkout (default: $KATAPULT_DIR)
  --flashtool PATH     Katapult flashtool.py path
  --dry-run            Resolve and print paths without requesting or flashing
  --yes                Skip the typed FLASH MAINBOARD confirmation
  -h, --help           Show this help
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --firmware)
      [ "$#" -ge 2 ] || die "--firmware requires a path"
      FIRMWARE="$2"
      shift 2
      ;;
    --device)
      [ "$#" -ge 2 ] || die "--device requires a path"
      DEVICE="$2"
      shift 2
      ;;
    --katapult-dir)
      [ "$#" -ge 2 ] || die "--katapult-dir requires a path"
      KATAPULT_DIR="$2"
      shift 2
      ;;
    --flashtool)
      [ "$#" -ge 2 ] || die "--flashtool requires a path"
      FLASHTOOL="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)"
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required"

if [ -z "$FLASHTOOL" ]; then
  FLASHTOOL="$KATAPULT_DIR/scripts/flashtool.py"
fi
[ -f "$FLASHTOOL" ] || die "Katapult flashtool.py not found: $FLASHTOOL"

[ -n "$FIRMWARE" ] || die "--firmware is required; select the exact image to flash"
[ -s "$FIRMWARE" ] || die "Mainboard firmware image is missing or empty: $FIRMWARE"

if [ -z "$DEVICE" ]; then
  shopt -s nullglob
  DEVICE_MATCHES=(
    /dev/serial/by-id/usb-Klipper_stm32f407xx_*-if00
    /dev/serial/by-id/usb-katapult_stm32f407xx_*-if00
  )
  shopt -u nullglob
  [ "${#DEVICE_MATCHES[@]}" -eq 1 ] ||
    die "Expected exactly one Q2 mainboard Klipper/Katapult device; pass --device"
  DEVICE="${DEVICE_MATCHES[0]}"
fi
[ -e "$DEVICE" ] || die "Mainboard serial device does not exist: $DEVICE"

info "Katapult flash tool: $FLASHTOOL"
info "Mainboard firmware:  $FIRMWARE"
info "Mainboard device:    $DEVICE"
info "Required app offset: $EXPECTED_APPLICATION_OFFSET"
warn "Flash only if matching Katapult is already installed on the mainboard."
warn "The wrong bootloader offset can make the MCU unbootable."

if [ "$DRY_RUN" -eq 1 ]; then
  info "Dry-run complete; no bootloader request or flash was performed."
  exit 0
fi

python3 -c "import serial" >/dev/null 2>&1 ||
  die "python3-serial is required by Katapult flashtool.py"

if [ "$ASSUME_YES" -ne 1 ]; then
  [ -t 0 ] || die "Interactive confirmation required; rerun in a terminal or pass --yes"
  printf 'Type FLASH MAINBOARD WITH MATCHING KATAPULT to continue: '
  read -r confirmation
  [ "$confirmation" = "FLASH MAINBOARD WITH MATCHING KATAPULT" ] ||
    die "Confirmation did not match"
fi

# For USB devices, flashtool.py detects a running Klipper application, requests
# Katapult, waits for USB re-enumeration, flashes, and verifies in one command.
python3 "$FLASHTOOL" --device "$DEVICE" --firmware "$FIRMWARE"

info "Mainboard flash and Katapult verification completed."
