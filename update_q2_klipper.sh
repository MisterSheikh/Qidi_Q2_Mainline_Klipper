#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KLIPPER_KNOWN_GOOD_COMMIT="$(
  bash "$SCRIPT_DIR/apply_patch.sh" --print-klipper-known-good
)"
KLIPPER_UPSTREAM_URL="${KLIPPER_UPSTREAM_URL:-https://github.com/Klipper3d/klipper.git}"
KLIPPER_UPSTREAM_REF="${KLIPPER_UPSTREAM_REF:-master}"
KLIPPER_PATCHES=(
  "patches/klipper/0001-stm32-add-GD32F425-USB-workaround.patch"
  "patches/klipper/0002-load_cell-add-CS1237-ADC-support.patch"
  "patches/klipper/0003-mcu-extend-Q2-multi-MCU-trigger-synchronization-time.patch"
  "patches/klipper/0004-stm32-add-Qidi-Q2-GD32F303-SPI2-mapping.patch"
  "patches/klipper/0005-stm32-add-Q2-GD32F425-MCU-temperature-support.patch"
  "patches/klipper/0006-stm32-add-Q2-GD32F303-120MHz-target.patch"
)

Q2_HOME_DIR="${HOME:?HOME is not set}"
ACTION="${1:-help}"
if [ "$#" -gt 0 ]; then
  shift
fi

ACTIVE_KLIPPER_DIR="$Q2_HOME_DIR/klipper"
KATAPULT_DIR="$Q2_HOME_DIR/katapult"
KLIPPY_ENV_DIR="$Q2_HOME_DIR/klippy-env"
PRINTER_DATA_DIR="$Q2_HOME_DIR/printer_data"
FIRMWARE_DIR=""
FIRMWARE_DIR_SET=0
BACKUP_ROOT="$Q2_HOME_DIR/q2-backups"
TOOLHEAD_DEVICE="/dev/ttyS4"
MAINBOARD_DEVICE=""
BUILD_JOBS=1
ASSUME_YES=0
FLASH_METHOD="prompt"
KLIPPER_REVISION_REQUEST="latest"
KLIPPER_BASE_COMMIT=""
KLIPPER_BASE_SHORT=""
KLIPPER_BASE_IS_KNOWN_GOOD=0
KLIPPER_LATEST_COMMIT=""
FALLBACK_ON_FAILURE=0
KLIPPER_WAS_STOPPED=0
BACKUP_DIR=""

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Update a Qidi Q2 installation by applying the Q2 patch series to a selected
upstream Klipper revision. The default is the latest upstream master revision;
the documented known-good revision is available as an explicit fallback.

Commands:
  check      Run read-only host, dependency, and path preflight checks.
  update     Stop Klipper, back up and update the active Klipper source and
             klippy-env, apply the Q2 patches, and build both MCU images.
             Katapult flashing is optional and explicitly selected.
  help       Show this help.

Options:
  --active-klipper PATH    Source path used by klipper.service
                           (default: $ACTIVE_KLIPPER_DIR)
  --katapult-dir PATH      Installed Katapult checkout
                           (default: $KATAPULT_DIR)
  --klippy-env PATH        Klippy Python virtual environment
                           (default: $KLIPPY_ENV_DIR)
  --printer-data PATH      Printer data directory
                           (default: $PRINTER_DATA_DIR)
  --klipper-revision REV   latest, known-good, or a full 40-character commit
                           (default: $KLIPPER_REVISION_REQUEST)
  --firmware-dir PATH      Output or existing firmware directory
                           (default: ~/q2-firmware/<selected-commit-short>)
  --backup-root PATH       Backup parent directory
                           (default: $BACKUP_ROOT)
  --main-device PATH       Runtime mainboard /dev/serial/by-id path
                           (auto-detected when exactly one match exists)
  --toolhead-device PATH   Toolhead UART path
                           (default: $TOOLHEAD_DEVICE)
  --jobs N                 Parallel build jobs (default: 1 for the stock AP)
  --flash-method METHOD    prompt, manual, or katapult (default: $FLASH_METHOD)
                           prompt asks after both images have been built;
                           manual leaves Klipper stopped after building;
                           katapult requires the matching installed bootloaders
  --yes                    Skip typed update confirmations; it does not select
                           a flash method when the default prompt is used
  -h, --help               Show this help

Examples:
  $(basename "$0") check
  $(basename "$0") update
  $(basename "$0") update --flash-method manual
  $(basename "$0") update --klipper-revision known-good --flash-method manual
  $(basename "$0") update --flash-method katapult --main-device <device>

The updater modifies the active Klipper installation only after stopping the
service and copying the complete source and Python environment into a timestamped
backup. It never installs or updates Katapult, rewrites printer configuration,
homes Z, or performs load-cell commissioning.

Automatic flashing is only for MCUs that already have the Katapult layout from
this repository's installation instructions: mainboard application offset
0x08008000 and toolhead application offset 0x08002000. If the bootloader is
stock, installed by another deployer, configured differently, or unknown, do
not select automatic flashing.

The check command does not contact upstream, apply patches, or build firmware.
EOF
}

info() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

print_katapult_layout_warning() {
  warn "AUTOMATIC FLASHING REQUIRES MATCHING KATAPULT BOOTLOADERS ON BOTH MCUS."
  warn "Required mainboard Klipper application offset: 0x08008000 (32 KiB)."
  warn "Required toolhead Klipper application offset: 0x08002000 (8 KiB)."
  warn "Do not auto-flash a stock, differently configured, deployer-modified,"
  warn "or unknown bootloader layout. The wrong offset can make an MCU unbootable."
  warn "This updater does not install, replace, or reconfigure Katapult."
}

on_exit() {
  local exit_code="$?"
  if [ "$exit_code" -ne 0 ] && [ "$KLIPPER_WAS_STOPPED" -eq 1 ]; then
    warn "The update stopped after klipper.service was taken offline."
    warn "Klipper has been left stopped so mismatched host/MCU versions are not run."
    if [ -n "$BACKUP_DIR" ]; then
      warn "Preserved rollback material: $BACKUP_DIR"
    fi
    if [ "$FALLBACK_ON_FAILURE" -eq 1 ]; then
      warn "The selected Klipper revision failed during patching or building."
      warn "To retry with the documented fallback, run:"
      printf '  %q update --klipper-revision known-good\n' "$SCRIPT_DIR/update_q2_klipper.sh" >&2
    fi
  fi
}
trap on_exit EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_file() {
  [ -f "$1" ] || die "Required file not found: $1"
}

parse_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --active-klipper)
        [ "$#" -ge 2 ] || die "--active-klipper requires a path"
        ACTIVE_KLIPPER_DIR="$2"
        shift 2
        ;;
      --katapult-dir)
        [ "$#" -ge 2 ] || die "--katapult-dir requires a path"
        KATAPULT_DIR="$2"
        shift 2
        ;;
      --klippy-env)
        [ "$#" -ge 2 ] || die "--klippy-env requires a path"
        KLIPPY_ENV_DIR="$2"
        shift 2
        ;;
      --printer-data)
        [ "$#" -ge 2 ] || die "--printer-data requires a path"
        PRINTER_DATA_DIR="$2"
        shift 2
        ;;
      --klipper-revision)
        [ "$#" -ge 2 ] || die "--klipper-revision requires latest, known-good, or a full commit"
        KLIPPER_REVISION_REQUEST="$2"
        shift 2
        ;;
      --firmware-dir)
        [ "$#" -ge 2 ] || die "--firmware-dir requires a path"
        FIRMWARE_DIR="$2"
        FIRMWARE_DIR_SET=1
        shift 2
        ;;
      --backup-root)
        [ "$#" -ge 2 ] || die "--backup-root requires a path"
        BACKUP_ROOT="$2"
        shift 2
        ;;
      --main-device)
        [ "$#" -ge 2 ] || die "--main-device requires a path"
        MAINBOARD_DEVICE="$2"
        shift 2
        ;;
      --toolhead-device)
        [ "$#" -ge 2 ] || die "--toolhead-device requires a path"
        TOOLHEAD_DEVICE="$2"
        shift 2
        ;;
      --jobs)
        [ "$#" -ge 2 ] || die "--jobs requires a positive integer"
        BUILD_JOBS="$2"
        shift 2
        ;;
      --flash-method)
        [ "$#" -ge 2 ] || die "--flash-method requires manual or katapult"
        FLASH_METHOD="$2"
        shift 2
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

  case "$BUILD_JOBS" in
    ''|*[!0-9]*)
      die "--jobs must be a positive integer"
      ;;
  esac
  [ "$BUILD_JOBS" -gt 0 ] || die "--jobs must be greater than zero"
  case "$FLASH_METHOD" in
    prompt|manual|katapult) ;;
    *) die "--flash-method must be prompt, manual, or katapult" ;;
  esac
  case "$KLIPPER_REVISION_REQUEST" in
    latest|known-good) ;;
    *)
      [[ "$KLIPPER_REVISION_REQUEST" =~ ^[0-9a-fA-F]{40}$ ]] ||
        die "--klipper-revision must be latest, known-good, or a full 40-character commit"
      KLIPPER_REVISION_REQUEST="${KLIPPER_REVISION_REQUEST,,}"
      ;;
  esac
}

check_meta_repository() {
  local required_patch

  require_file "$SCRIPT_DIR/apply_patch.sh"
  require_file "$SCRIPT_DIR/klipper_patch/.main_mcu.config"
  require_file "$SCRIPT_DIR/klipper_patch/.th_mcu.config"
  for required_patch in "${KLIPPER_PATCHES[@]}"; do
    require_file "$SCRIPT_DIR/$required_patch"
  done

}

check_katapult_flash_dependencies() {
  require_file "$KATAPULT_DIR/scripts/flashtool.py"
  require_file "$SCRIPT_DIR/qidi_mcu_flash_scripts/flash_main.sh"
  require_file "$SCRIPT_DIR/qidi_mcu_flash_scripts/flash_th.sh"
  [ -x "$SCRIPT_DIR/qidi_mcu_flash_scripts/flash_main.sh" ] ||
    die "Mainboard flash wrapper is not executable"
  [ -x "$SCRIPT_DIR/qidi_mcu_flash_scripts/flash_th.sh" ] ||
    die "Toolhead flash wrapper is not executable"
  python3 -c "import serial" >/dev/null 2>&1 ||
    die "python3-serial is missing; install it before flashing"
}

check_service_path() {
  local environment_file
  local expected_klippy_path="$ACTIVE_KLIPPER_DIR/klippy/klippy.py"
  local main_pid
  local runtime_arguments=""
  local service_definition

  require_file "$expected_klippy_path"
  service_definition="$(systemctl cat klipper 2>/dev/null)" ||
    die "Unable to inspect klipper.service"

  # Prefer the running process because KIAUH commonly stores the source path
  # inside KLIPPER_ARGS instead of spelling it out in the systemd unit.
  main_pid="$(systemctl show klipper --property=MainPID --value 2>/dev/null || true)"
  case "$main_pid" in
    ''|0|*[!0-9]*)
      ;;
    *)
      if [ -r "/proc/$main_pid/cmdline" ]; then
        runtime_arguments="$(tr '\0' '\n' <"/proc/$main_pid/cmdline")"
        if grep -Fqx "$expected_klippy_path" <<<"$runtime_arguments"; then
          return
        fi
      fi
      ;;
  esac

  # A unit may reference the source directly.
  if grep -Fq "$expected_klippy_path" <<<"$service_definition"; then
    return
  fi

  # Or it may obtain KLIPPER_ARGS from one or more EnvironmentFile entries.
  # Inspect them as text; never source or execute a service environment file.
  while IFS= read -r environment_file; do
    environment_file="${environment_file#-}"
    if [ -r "$environment_file" ] &&
        grep -Fq "$expected_klippy_path" "$environment_file"; then
      return
    fi
  done < <(
    sed -n -E \
      's/^[[:space:]]*EnvironmentFile=-?([^[:space:]]+).*/\1/p' \
      <<<"$service_definition"
  )

  warn "Expected active Klipper entry point: $expected_klippy_path"
  if [ -n "$runtime_arguments" ]; then
    warn "Running klipper.service arguments did not contain that exact path:"
    printf '%s\n' "$runtime_arguments" >&2
  fi
  die "Unable to confirm that --active-klipper is the source used by klipper.service"
}

check_runtime_dependencies() {
  require_command cat
  require_command cp
  require_command date
  require_command git
  require_command grep
  require_command install
  require_command journalctl
  require_command ls
  require_command make
  require_command mkdir
  require_command python3
  require_command sha256sum
  require_command sed
  require_command sleep
  require_command sudo
  require_command systemctl
  require_command tail
  require_command tee
  require_command tr
  require_command arm-none-eabi-gcc
  require_command arm-none-eabi-objcopy

  check_meta_repository

  [ -d "$ACTIVE_KLIPPER_DIR/.git" ] ||
    die "Active Klipper source is not a Git checkout: $ACTIVE_KLIPPER_DIR"
  [ -x "$KLIPPY_ENV_DIR/bin/python" ] ||
    die "Klippy virtual environment not found: $KLIPPY_ENV_DIR"
  "$KLIPPY_ENV_DIR/bin/python" -m pip --version >/dev/null 2>&1 ||
    die "pip is unavailable in the Klippy environment: $KLIPPY_ENV_DIR"
  [ -d "$PRINTER_DATA_DIR/config" ] ||
    die "Printer configuration directory not found: $PRINTER_DATA_DIR/config"

  if [ "$FLASH_METHOD" = "katapult" ]; then
    check_katapult_flash_dependencies
  fi
}

resolve_klipper_revision() {
  info "Fetching upstream Klipper $KLIPPER_UPSTREAM_REF"
  git -C "$ACTIVE_KLIPPER_DIR" fetch "$KLIPPER_UPSTREAM_URL" "$KLIPPER_UPSTREAM_REF"
  KLIPPER_LATEST_COMMIT="$(git -C "$ACTIVE_KLIPPER_DIR" rev-parse FETCH_HEAD)"

  case "$KLIPPER_REVISION_REQUEST" in
    latest)
      KLIPPER_BASE_COMMIT="$KLIPPER_LATEST_COMMIT"
      ;;
    known-good)
      KLIPPER_BASE_COMMIT="$KLIPPER_KNOWN_GOOD_COMMIT"
      ;;
    *)
      KLIPPER_BASE_COMMIT="$KLIPPER_REVISION_REQUEST"
      ;;
  esac

  if ! git -C "$ACTIVE_KLIPPER_DIR" cat-file -e "$KLIPPER_BASE_COMMIT^{commit}" 2>/dev/null; then
    git -C "$ACTIVE_KLIPPER_DIR" fetch "$KLIPPER_UPSTREAM_URL" "$KLIPPER_BASE_COMMIT"
  fi
  git -C "$ACTIVE_KLIPPER_DIR" cat-file -e "$KLIPPER_BASE_COMMIT^{commit}" ||
    die "Selected Klipper commit was not fetched: $KLIPPER_BASE_COMMIT"

  if ! git -C "$ACTIVE_KLIPPER_DIR" merge-base --is-ancestor \
      "$KLIPPER_BASE_COMMIT" "$KLIPPER_LATEST_COMMIT"; then
    if [ "$(git -C "$ACTIVE_KLIPPER_DIR" rev-parse --is-shallow-repository)" = "true" ]; then
      info "Deepening the shallow checkout to verify upstream ancestry"
      git -C "$ACTIVE_KLIPPER_DIR" fetch --unshallow \
        "$KLIPPER_UPSTREAM_URL" "$KLIPPER_UPSTREAM_REF"
      KLIPPER_LATEST_COMMIT="$(git -C "$ACTIVE_KLIPPER_DIR" rev-parse FETCH_HEAD)"
    fi
  fi
  git -C "$ACTIVE_KLIPPER_DIR" merge-base --is-ancestor \
    "$KLIPPER_BASE_COMMIT" "$KLIPPER_LATEST_COMMIT" ||
    die "Selected commit is not in the fetched upstream $KLIPPER_UPSTREAM_REF history"

  KLIPPER_BASE_COMMIT="$(git -C "$ACTIVE_KLIPPER_DIR" rev-parse "$KLIPPER_BASE_COMMIT^{commit}")"
  KLIPPER_BASE_SHORT="${KLIPPER_BASE_COMMIT:0:8}"
  if [ "$KLIPPER_BASE_COMMIT" = "$KLIPPER_KNOWN_GOOD_COMMIT" ]; then
    KLIPPER_BASE_IS_KNOWN_GOOD=1
  else
    KLIPPER_BASE_IS_KNOWN_GOOD=0
  fi
  if [ "$FIRMWARE_DIR_SET" -eq 0 ]; then
    FIRMWARE_DIR="$Q2_HOME_DIR/q2-firmware/$KLIPPER_BASE_SHORT"
  fi
}

update_active_source() {
  info "Updating active Klipper source to $KLIPPER_BASE_COMMIT"

  # The complete pre-update checkout is already preserved in BACKUP_DIR.
  # Return the active checkout to the selected upstream base, remove generated
  # build material, and then apply the Q2 patch series.
  git -C "$ACTIVE_KLIPPER_DIR" reset --hard "$KLIPPER_BASE_COMMIT"
  git -C "$ACTIVE_KLIPPER_DIR" clean -fdx
  KLIPPER_DIR="$ACTIVE_KLIPPER_DIR" bash "$SCRIPT_DIR/apply_patch.sh" klipper

  git -C "$ACTIVE_KLIPPER_DIR" diff --check ||
    die "The applied Q2 patch series contains whitespace errors"
  info "Q2 patches applied"
}

patched_source_sha256() {
  local file_hash
  local LC_ALL=C
  local untracked_path

  {
    git -C "$ACTIVE_KLIPPER_DIR" diff --binary --no-ext-diff \
      "$KLIPPER_BASE_COMMIT" --
    while IFS= read -r -d '' untracked_path; do
      file_hash="$(sha256sum -- "$ACTIVE_KLIPPER_DIR/$untracked_path")"
      file_hash="${file_hash%% *}"
      printf 'untracked %s %s\n' "$file_hash" "$untracked_path"
    done < <(
      git -C "$ACTIVE_KLIPPER_DIR" ls-files \
        --others --exclude-standard -z
    )
  } | sha256sum | sed 's/[[:space:]].*$//'
}

update_klippy_environment() {
  local env_python="$KLIPPY_ENV_DIR/bin/python"

  info "Updating the existing Klippy Python environment"
  "$env_python" -m pip install \
    -r "$ACTIVE_KLIPPER_DIR/scripts/klippy-requirements.txt"

  if ! "$env_python" -c "import numpy" >/dev/null 2>&1; then
    info "Installing missing Q2 Klippy dependency: numpy"
    "$env_python" -m pip install numpy
  fi

  "$env_python" -c "import numpy, serial; print('Klippy dependencies OK')"
}

require_config_value() {
  local config_file="$1"
  local expected_line="$2"
  grep -Fqx "$expected_line" "$config_file" ||
    die "Expected build setting missing from $config_file: $expected_line"
}

build_one_firmware() {
  local board_name="$1"
  local saved_config="$2"
  local output_file="$3"

  info "Building $board_name firmware with $BUILD_JOBS job(s)"
  cp "$saved_config" "$ACTIVE_KLIPPER_DIR/.config"
  make -C "$ACTIVE_KLIPPER_DIR" olddefconfig

  case "$board_name" in
    mainboard)
      require_config_value "$ACTIVE_KLIPPER_DIR/.config" 'CONFIG_MCU="stm32f407xx"'
      require_config_value "$ACTIVE_KLIPPER_DIR/.config" \
        'CONFIG_MACH_GD32F425_Q2=y'
      require_config_value "$ACTIVE_KLIPPER_DIR/.config" \
        'CONFIG_CLOCK_FREQ=168000000'
      require_config_value "$ACTIVE_KLIPPER_DIR/.config" \
        'CONFIG_FLASH_APPLICATION_ADDRESS=0x8008000'
      require_config_value "$ACTIVE_KLIPPER_DIR/.config" \
        'CONFIG_STM32F4_GD32_USB_INIT_WORKAROUND=y'
      require_config_value "$ACTIVE_KLIPPER_DIR/.config" 'CONFIG_WANT_CS1237=y'
      ;;
    toolhead)
      require_config_value "$ACTIVE_KLIPPER_DIR/.config" 'CONFIG_MCU="stm32f103xe"'
      require_config_value "$ACTIVE_KLIPPER_DIR/.config" \
        'CONFIG_FLASH_APPLICATION_ADDRESS=0x8002000'
      require_config_value "$ACTIVE_KLIPPER_DIR/.config" 'CONFIG_SERIAL_BAUD=500000'
      require_config_value "$ACTIVE_KLIPPER_DIR/.config" 'CONFIG_WANT_CS1237=y'
      ;;
    *)
      die "Internal error: unsupported board $board_name"
      ;;
  esac

  make -C "$ACTIVE_KLIPPER_DIR" clean
  make -C "$ACTIVE_KLIPPER_DIR" -j"$BUILD_JOBS"
  [ -s "$ACTIVE_KLIPPER_DIR/out/klipper.bin" ] ||
    die "$board_name build did not produce out/klipper.bin"
  install -m 0644 "$ACTIVE_KLIPPER_DIR/out/klipper.bin" "$output_file"
}

build_firmware() {
  local mainboard_output
  local toolhead_output

  mkdir -p "$FIRMWARE_DIR"
  mainboard_output="$FIRMWARE_DIR/q2-mainboard-klipper-$KLIPPER_BASE_SHORT.bin"
  toolhead_output="$FIRMWARE_DIR/q2-toolhead-klipper-$KLIPPER_BASE_SHORT.bin"

  build_one_firmware \
    mainboard \
    "$SCRIPT_DIR/klipper_patch/.main_mcu.config" \
    "$mainboard_output"
  build_one_firmware \
    toolhead \
    "$SCRIPT_DIR/klipper_patch/.th_mcu.config" \
    "$toolhead_output"

  info "Recording firmware checksums"
  (
    cd "$FIRMWARE_DIR"
    sha256sum "$(basename "$mainboard_output")" "$(basename "$toolhead_output")"
  ) | tee "$FIRMWARE_DIR/SHA256SUMS"
  printf '%s\n' "$KLIPPER_BASE_COMMIT" >"$FIRMWARE_DIR/KLIPPER_BASE"
  {
    printf 'requested=%s\n' "$KLIPPER_REVISION_REQUEST"
    printf 'resolved=%s\n' "$KLIPPER_BASE_COMMIT"
  } >"$FIRMWARE_DIR/KLIPPER_REVISION"
  patched_source_sha256 >"$FIRMWARE_DIR/PATCHED_SOURCE_SHA256"
  (
    cd "$SCRIPT_DIR"
    sha256sum -- "${KLIPPER_PATCHES[@]}"
  ) >"$FIRMWARE_DIR/PATCHSET_SHA256SUMS"
  (
    cd "$SCRIPT_DIR"
    sha256sum -- klipper_patch/.main_mcu.config klipper_patch/.th_mcu.config
  ) >"$FIRMWARE_DIR/BUILD_CONFIG_SHA256SUMS"

  info "Firmware is ready in $FIRMWARE_DIR"
}

verify_firmware_artifacts() {
  local actual_base
  local actual_source_sha256
  local expected_source_sha256
  local mainboard_firmware="$FIRMWARE_DIR/q2-mainboard-klipper-$KLIPPER_BASE_SHORT.bin"
  local toolhead_firmware="$FIRMWARE_DIR/q2-toolhead-klipper-$KLIPPER_BASE_SHORT.bin"

  require_file "$mainboard_firmware"
  require_file "$toolhead_firmware"
  require_file "$FIRMWARE_DIR/SHA256SUMS"
  require_file "$FIRMWARE_DIR/KLIPPER_BASE"
  require_file "$FIRMWARE_DIR/KLIPPER_REVISION"
  require_file "$FIRMWARE_DIR/PATCHED_SOURCE_SHA256"
  require_file "$FIRMWARE_DIR/PATCHSET_SHA256SUMS"
  require_file "$FIRMWARE_DIR/BUILD_CONFIG_SHA256SUMS"

  grep -Fqx "$KLIPPER_BASE_COMMIT" "$FIRMWARE_DIR/KLIPPER_BASE" ||
    die "Firmware manifest does not match the selected Klipper base"
  actual_base="$(git -C "$ACTIVE_KLIPPER_DIR" rev-parse HEAD)"
  [ "$actual_base" = "$KLIPPER_BASE_COMMIT" ] ||
    die "Active Klipper checkout is no longer at the selected base"
  expected_source_sha256="$(cat "$FIRMWARE_DIR/PATCHED_SOURCE_SHA256")"
  actual_source_sha256="$(patched_source_sha256)"
  [ "$expected_source_sha256" = "$actual_source_sha256" ] ||
    die "Firmware was not built from the active patched source"
  (
    cd "$SCRIPT_DIR"
    sha256sum -c "$FIRMWARE_DIR/PATCHSET_SHA256SUMS"
    sha256sum -c "$FIRMWARE_DIR/BUILD_CONFIG_SHA256SUMS"
  )
  (
    cd "$FIRMWARE_DIR"
    sha256sum -c SHA256SUMS
  )
}

resolve_mainboard_device() {
  local -a device_matches=()

  if [ -z "$MAINBOARD_DEVICE" ]; then
    shopt -s nullglob
    device_matches=(
      /dev/serial/by-id/usb-Klipper_stm32f407xx_*-if00
      /dev/serial/by-id/usb-katapult_stm32f407xx_*-if00
    )
    shopt -u nullglob
    if [ "${#device_matches[@]}" -ne 1 ]; then
      die "Expected exactly one Q2 mainboard Klipper/Katapult device; specify --main-device"
    fi
    MAINBOARD_DEVICE="${device_matches[0]}"
  fi
  [ -e "$MAINBOARD_DEVICE" ] ||
    die "Mainboard serial device does not exist: $MAINBOARD_DEVICE"
}

create_backup() {
  local backup_stamp
  backup_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_DIR="$BACKUP_ROOT/$backup_stamp-$KLIPPER_BASE_SHORT"
  [ ! -e "$BACKUP_DIR" ] || die "Backup destination already exists: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"

  info "Copying the active Klipper source and Python environment to $BACKUP_DIR"
  cp -a "$ACTIVE_KLIPPER_DIR" "$BACKUP_DIR/klipper"
  cp -a "$KLIPPY_ENV_DIR" "$BACKUP_DIR/klippy-env"
  cp -a "$PRINTER_DATA_DIR/config" "$BACKUP_DIR/printer-config"
  git -C "$ACTIVE_KLIPPER_DIR" rev-parse HEAD \
    >"$BACKUP_DIR/active-klipper-head.txt" 2>&1 || true
  git -C "$ACTIVE_KLIPPER_DIR" status --short \
    >"$BACKUP_DIR/active-klipper-status.txt" 2>&1 || true
  systemctl cat klipper \
    >"$BACKUP_DIR/klipper.service.txt" 2>&1 || true
  ls -l /dev/serial/by-id \
    >"$BACKUP_DIR/serial-by-id.txt" 2>&1 || true

  warn "Running MCU firmware cannot be read back by this script."
  warn "Keep your previous known-good firmware images with this backup."
}

confirm_update() {
  local required_confirmation="UPDATE Q2"

  printf '\n'
  printf 'Requested revision:   %s\n' "$KLIPPER_REVISION_REQUEST"
  printf 'Resolved base:        %s\n' "$KLIPPER_BASE_COMMIT"
  printf 'Active source:        %s\n' "$ACTIVE_KLIPPER_DIR"
  printf 'Klippy environment:   %s\n' "$KLIPPY_ENV_DIR"
  printf 'Firmware directory:   %s\n' "$FIRMWARE_DIR"
  printf 'Backup root:          %s\n' "$BACKUP_ROOT"
  printf 'Flash method:         %s\n' "$FLASH_METHOD"
  printf '\n'
  warn "Klipper will be stopped before the source and environment backups are made."
  case "$FLASH_METHOD" in
    katapult)
      print_katapult_layout_warning
      warn "Existing MCU firmware cannot be read back; retain known-good images."
      required_confirmation="UPDATE Q2 WITH MATCHING KATAPULT"
      ;;
    prompt)
      warn "Both images will be built before an interactive flash choice is shown."
      warn "No firmware will be flashed unless matching Katapult is selected."
      ;;
    manual)
      warn "Manual mode leaves Klipper stopped after building the firmware images."
      ;;
  esac

  if [ "$ASSUME_YES" -eq 1 ]; then
    warn "The typed update confirmation was bypassed with --yes."
    return
  fi

  [ -t 0 ] || die "Interactive confirmation required; rerun from a terminal or use --yes"
  printf 'Type %s to stop Klipper and update the active installation: ' \
    "$required_confirmation"
  read -r confirmation
  [ "$confirmation" = "$required_confirmation" ] ||
    die "Confirmation did not match; no update performed"
}

select_post_build_flash_method() {
  local confirmation
  local selection

  [ "$FLASH_METHOD" = "prompt" ] || return

  printf '\n'
  info "Both Q2 Klipper firmware images have been built and verified"
  print_katapult_layout_warning
  printf '\nChoose what happens next:\n'
  printf '  1) Stop here without flashing. Use this for stock, alternative,\n'
  printf '     deployer-modified, or unknown bootloader layouts. [safe default]\n'
  printf '  2) Flash both MCUs through already-installed matching Katapult.\n'

  if [ ! -t 0 ]; then
    warn "No interactive terminal is available; selecting the safe no-flash path."
    FLASH_METHOD="manual"
    return
  fi

  printf 'Select 1 or 2 [1]: '
  read -r selection
  case "$selection" in
    ''|1)
      FLASH_METHOD="manual"
      ;;
    2)
      printf 'Type MATCHING KATAPULT OFFSETS to confirm both installed layouts: '
      read -r confirmation
      if [ "$confirmation" = "MATCHING KATAPULT OFFSETS" ]; then
        FLASH_METHOD="katapult"
      else
        warn "Layout confirmation did not match; selecting the safe no-flash path."
        FLASH_METHOD="manual"
      fi
      ;;
    *)
      warn "Unknown selection; selecting the safe no-flash path."
      FLASH_METHOD="manual"
      ;;
  esac
}

stop_klipper() {
  info "Stopping klipper.service"
  sudo systemctl stop klipper
  KLIPPER_WAS_STOPPED=1
  if systemctl is-active --quiet klipper; then
    die "klipper.service is still active"
  fi
}

flash_with_katapult() {
  local mainboard_firmware="$FIRMWARE_DIR/q2-mainboard-klipper-$KLIPPER_BASE_SHORT.bin"
  local toolhead_firmware="$FIRMWARE_DIR/q2-toolhead-klipper-$KLIPPER_BASE_SHORT.bin"

  check_katapult_flash_dependencies
  resolve_mainboard_device
  [ -e "$TOOLHEAD_DEVICE" ] || die "Toolhead UART does not exist: $TOOLHEAD_DEVICE"

  info "Flashing the toolhead through the hardened Katapult wrapper"
  "$SCRIPT_DIR/qidi_mcu_flash_scripts/flash_th.sh" \
    --firmware "$toolhead_firmware" \
    --device "$TOOLHEAD_DEVICE" \
    --katapult-dir "$KATAPULT_DIR" \
    --yes

  info "Flashing the mainboard through the hardened Katapult wrapper"
  "$SCRIPT_DIR/qidi_mcu_flash_scripts/flash_main.sh" \
    --firmware "$mainboard_firmware" \
    --device "$MAINBOARD_DEVICE" \
    --katapult-dir "$KATAPULT_DIR" \
    --yes
}

print_manual_flash_handoff() {
  warn "Klipper remains stopped until matching firmware is installed on both MCUs."
  printf '\nMainboard firmware:\n  %s\n' \
    "$FIRMWARE_DIR/q2-mainboard-klipper-$KLIPPER_BASE_SHORT.bin"
  printf 'Toolhead firmware:\n  %s\n' \
    "$FIRMWARE_DIR/q2-toolhead-klipper-$KLIPPER_BASE_SHORT.bin"
  printf '\nThese images use the Katapult application offsets from this repository:\n'
  printf '  mainboard: 0x08008000 (32 KiB)\n'
  printf '  toolhead:  0x08002000 (8 KiB)\n'
  printf 'Do not flash them onto a stock, alternative, deployer-modified, or unknown\n'
  printf 'bootloader layout. Verify that layout and rebuild with its matching build\n'
  printf 'configuration when necessary. Start klipper.service only after both MCUs\n'
  printf 'match the host.\n'
}

start_and_inspect_klipper() {
  info "Starting klipper.service"
  sudo systemctl start klipper
  sleep 3

  if ! systemctl is-active --quiet klipper; then
    warn "klipper.service did not become active."
    journalctl -u klipper -n 80 --no-pager || true
    die "Klipper startup failed"
  fi
  KLIPPER_WAS_STOPPED=0

  systemctl status klipper --no-pager || true
  if [ -f "$PRINTER_DATA_DIR/logs/klippy.log" ]; then
    tail -n 80 "$PRINTER_DATA_DIR/logs/klippy.log"
  fi

  warn "Do not home Z yet. Confirm both MCUs and CS1237 are healthy, then follow"
  warn "docs/LOAD_CELL_CALIBRATION.md and the commissioning order in docs/INSTALL.md."
}

run_check() {
  info "Running Q2 update preflight"
  check_runtime_dependencies
  check_service_path
  if [ "$FLASH_METHOD" = "katapult" ]; then
    resolve_mainboard_device
    [ -e "$TOOLHEAD_DEVICE" ] ||
      die "Toolhead UART does not exist: $TOOLHEAD_DEVICE"
  fi
  info "Preflight passed"
  warn "Preflight checks the local installation only."
}

run_update() {
  run_check
  resolve_klipper_revision
  confirm_update
  mkdir -p "$BACKUP_ROOT"
  stop_klipper
  create_backup
  if [ "$KLIPPER_BASE_IS_KNOWN_GOOD" -eq 0 ]; then
    FALLBACK_ON_FAILURE=1
  fi
  update_active_source
  FALLBACK_ON_FAILURE=0
  update_klippy_environment
  if [ "$KLIPPER_BASE_IS_KNOWN_GOOD" -eq 0 ]; then
    FALLBACK_ON_FAILURE=1
  fi
  build_firmware
  verify_firmware_artifacts
  FALLBACK_ON_FAILURE=0

  select_post_build_flash_method

  if [ "$FLASH_METHOD" = "manual" ]; then
    print_manual_flash_handoff
    return
  fi

  flash_with_katapult
  start_and_inspect_klipper
}

parse_options "$@"

case "$ACTION" in
  check)
    run_check
    ;;
  update)
    run_update
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    die "Unknown command: $ACTION"
    ;;
esac
