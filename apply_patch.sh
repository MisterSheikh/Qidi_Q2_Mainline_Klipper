#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KLIPPER_DIR="${KLIPPER_DIR:-$HOME/klipper}"
KATAPULT_DIR="${KATAPULT_DIR:-$HOME/katapult}"
TARGET="all"
CHECK_ONLY=0
TARGET_SEEN=0

KLIPPER_PATCHES=(
  "$SCRIPT_DIR/patches/klipper/0001-stm32-add-GD32F425-USB-workaround.patch"
  "$SCRIPT_DIR/patches/klipper/0002-load_cell-add-CS1237-ADC-support.patch"
  "$SCRIPT_DIR/patches/klipper/0003-mcu-extend-Q2-multi-MCU-trigger-synchronization-time.patch"
  "$SCRIPT_DIR/patches/klipper/0004-stm32-add-Qidi-Q2-GD32F303-SPI2-mapping.patch"
  "$SCRIPT_DIR/patches/klipper/0005-stm32-add-Q2-GD32F425-MCU-temperature-support.patch"
)
KATAPULT_PATCH="$SCRIPT_DIR/patches/katapult/0001-q2-mainboard-usb.patch"

KLIPPER_KNOWN_GOOD_COMMIT="9c1ae230eaebd5ec4df76d5a87537e2f35defab0"
KATAPULT_KNOWN_GOOD_COMMIT="b0bf421069e2aab810db43d6e15f38817d981451"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check] [klipper|katapult|all]
       $(basename "$0") --print-klipper-known-good
       $(basename "$0") --print-katapult-known-good

The default target is all. Patches are checked against each checkout's current
HEAD. If the check fails, use the known-good revision printed by the helper.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

require_git_repo() {
  local repo="$1"
  if [ ! -d "$repo/.git" ]; then
    die "Not a git repository: $repo"
  fi
}

require_clean_repo() {
  local repo="$1"
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    die "Repository has local changes: $repo (clean it first, then rerun)"
  fi
}

describe_revision() {
  local component="$1"
  local head="$2"
  local known_good="$3"

  if [ "$head" = "$known_good" ]; then
    echo "$component base: $head (known-good)"
  else
    echo "$component base: $head"
    warn "This revision is not listed in docs/KNOWN_GOOD_MATRIX.md; build and test it before use."
  fi
}

print_fallback() {
  local component="$1"
  local repo="$2"
  local known_good="$3"

  warn "$component patch compatibility check failed; the checkout was not modified."
  warn "To use the documented fallback, run:"
  printf '  git -C %q checkout %q\n' "$repo" "$known_good" >&2
}

validate_patch_series() {
  local component="$1"
  local repo="$2"
  local known_good="$3"
  shift 3
  local head
  local patch

  require_git_repo "$repo"
  require_clean_repo "$repo"
  for patch in "$@"; do
    [ -f "$patch" ] || die "Missing patch file: $patch"
    echo "Checking $(basename "$patch")..."
  done

  head="$(git -C "$repo" rev-parse HEAD)"
  describe_revision "$component" "$head" "$known_good"
  if ! git -C "$repo" apply --check "$@"; then
    print_fallback "$component" "$repo" "$known_good"
    return 1
  fi
}

validate_klipper() {
  echo "Using Klipper repo: $KLIPPER_DIR"
  validate_patch_series \
    "Klipper" "$KLIPPER_DIR" "$KLIPPER_KNOWN_GOOD_COMMIT" \
    "${KLIPPER_PATCHES[@]}"
}

validate_katapult() {
  echo "Using Katapult repo: $KATAPULT_DIR"
  validate_patch_series \
    "Katapult" "$KATAPULT_DIR" "$KATAPULT_KNOWN_GOOD_COMMIT" \
    "$KATAPULT_PATCH"
}

apply_klipper_patches() {
  git -C "$KLIPPER_DIR" apply "${KLIPPER_PATCHES[@]}"
}

apply_katapult_patch() {
  git -C "$KATAPULT_DIR" apply "$KATAPULT_PATCH"
}

for argument in "$@"; do
  case "$argument" in
    --check)
      CHECK_ONLY=1
      ;;
    klipper|katapult|all)
      [ "$TARGET_SEEN" -eq 0 ] || die "Only one patch target may be specified"
      TARGET="$argument"
      TARGET_SEEN=1
      ;;
    --print-klipper-known-good|--print-klipper-target)
      [ "$#" -eq 1 ] || die "$argument cannot be combined with other arguments"
      printf '%s\n' "$KLIPPER_KNOWN_GOOD_COMMIT"
      exit 0
      ;;
    --print-katapult-known-good|--print-katapult-target)
      [ "$#" -eq 1 ] || die "$argument cannot be combined with other arguments"
      printf '%s\n' "$KATAPULT_KNOWN_GOOD_COMMIT"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown argument: $argument"
      ;;
  esac
done

case "$TARGET" in
  klipper)
    validate_klipper
    [ "$CHECK_ONLY" -eq 1 ] || apply_klipper_patches
    ;;
  katapult)
    validate_katapult
    [ "$CHECK_ONLY" -eq 1 ] || apply_katapult_patch
    ;;
  all)
    # Validate both repositories before modifying either one.
    validate_klipper
    validate_katapult
    if [ "$CHECK_ONLY" -eq 0 ]; then
      apply_klipper_patches
      apply_katapult_patch
    fi
    ;;
esac

echo
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "Patch compatibility check complete; no files were modified."
else
  echo "Patch apply complete."
  echo "Build and test the selected revision before flashing."
fi
