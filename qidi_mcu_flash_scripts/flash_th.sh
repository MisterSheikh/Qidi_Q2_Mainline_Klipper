#!/usr/bin/env bash
set -Eeuo pipefail

KATAPULT_DIR="${KATAPULT_DIR:-${HOME:?HOME is not set}/katapult}"
FLASHTOOL=""
FIRMWARE=""
DEVICE="${TOOLHEAD_DEVICE:-/dev/ttyS4}"
BAUD="${TOOLHEAD_BAUD:-500000}"
ASSUME_YES=0
DRY_RUN=0
EXPECTED_APPLICATION_OFFSET="0x08002000"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Flash Qidi Q2 toolhead Klipper firmware through an existing Katapult
bootloader. Katapult itself is not installed or updated by this script.

Only use this wrapper when the installed toolhead Katapult expects the
Klipper application at $EXPECTED_APPLICATION_OFFSET (8 KiB). Do not use it
with a stock, differently configured, deployer-modified, or unknown bootloader.

Options:
  --firmware PATH      Toolhead Klipper image (required)
  --device PATH        Toolhead UART device (default: $DEVICE)
  --baud RATE          Toolhead UART baud rate (default: $BAUD)
  --katapult-dir PATH  Katapult checkout (default: $KATAPULT_DIR)
  --flashtool PATH     Katapult flashtool.py path
  --dry-run            Resolve and print paths without requesting or flashing
  --yes                Skip the typed FLASH TOOLHEAD confirmation
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
    --baud)
      [ "$#" -ge 2 ] || die "--baud requires a rate"
      BAUD="$2"
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

case "$BAUD" in
  ''|*[!0-9]*) die "--baud must be a positive integer" ;;
esac
[ "$BAUD" -gt 0 ] || die "--baud must be greater than zero"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

if [ -z "$FLASHTOOL" ]; then
  FLASHTOOL="$KATAPULT_DIR/scripts/flashtool.py"
fi
[ -f "$FLASHTOOL" ] || die "Katapult flashtool.py not found: $FLASHTOOL"

[ -n "$FIRMWARE" ] || die "--firmware is required; select the exact image to flash"
[ -s "$FIRMWARE" ] || die "Toolhead firmware image is missing or empty: $FIRMWARE"
[ -e "$DEVICE" ] || die "Toolhead UART device does not exist: $DEVICE"

info "Katapult flash tool: $FLASHTOOL"
info "Toolhead firmware:   $FIRMWARE"
info "Toolhead UART:       $DEVICE"
info "Toolhead baud:       $BAUD"
info "Required app offset: $EXPECTED_APPLICATION_OFFSET"
warn "Flash only if matching Katapult is already installed on the toolhead."
warn "The wrong bootloader offset can make the MCU unbootable."

if [ "$DRY_RUN" -eq 1 ]; then
  info "Dry-run complete; no bootloader request or flash was performed."
  exit 0
fi

python3 -c "import serial" >/dev/null 2>&1 ||
  die "python3-serial is required by Katapult flashtool.py"

if [ "$ASSUME_YES" -ne 1 ]; then
  [ -t 0 ] || die "Interactive confirmation required; rerun in a terminal or pass --yes"
  printf 'Type FLASH TOOLHEAD WITH MATCHING KATAPULT to continue: '
  read -r confirmation
  [ "$confirmation" = "FLASH TOOLHEAD WITH MATCHING KATAPULT" ] ||
    die "Confirmation did not match"
fi

# A UART device has no USB descriptors for flashtool.py to identify, so request
# Katapult first and then perform the verified firmware transfer.
python3 "$FLASHTOOL" --baud "$BAUD" --device "$DEVICE" --request-bootloader
python3 "$FLASHTOOL" --baud "$BAUD" --device "$DEVICE" --firmware "$FIRMWARE"

info "Toolhead flash and Katapult verification completed."
