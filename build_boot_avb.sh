#!/usr/bin/env bash
#
# Standalone nashc boot image repacker + AVB signer.
#
# This script is intentionally NOT hooked into the Android/Lineage build.
# Full ROM builds already get their AVB settings from the device tree.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$ROOT_DIR/tools/nashc-avb"
STATE_DIR="$ROOT_DIR/.nashc-avb"
TEMPLATE_BOOT="$STATE_DIR/template-boot.img"

MKBOOTIMG="$TOOLS_DIR/mkbootimg.py"
UNPACK_BOOTIMG="$TOOLS_DIR/unpack_bootimg.py"
AVBTOOL="$TOOLS_DIR/avbtool.py"
DEFAULT_AVB_KEY="$TOOLS_DIR/testkey_rsa2048.pem"

# Keep these in sync with device/realme/nashc/BoardConfig.mk.
BOOT_PARTITION_SIZE=33554432
AVB_ALGORITHM="SHA256_RSA2048"
AVB_HASH_ALGORITHM="sha256"
AVB_ROLLBACK_INDEX=0
AVB_ROLLBACK_INDEX_LOCATION=3

BASE_BOOT=""
KERNEL_IMAGE=""
DTB_IMAGE=""
OUTPUT_IMAGE="$STATE_DIR/nashc-AVB-boot.img"
AVB_KEY="$DEFAULT_AVB_KEY"
NO_DTB=0

usage() {
    cat <<'EOF'
Usage:
  bash build_boot_avb.sh --base-boot /path/to/boot.img [options]
  bash build_boot_avb.sh [options]

First run:
  Pass --base-boot from the SAME ROM/build family you are targeting.
  It is cached in .nashc-avb/template-boot.img.

Later runs:
  The cached template is reused, so --base-boot is not required.

Options:
  --base-boot FILE   Refresh/cache the boot template.
  --kernel FILE      Built kernel image. Image.gz or Image is accepted.
  --dtb FILE         Built mt6785.dtb to replace the template DTB.
  --no-dtb            Keep the DTB from the template boot image.
  --output FILE      Output path.
  --key FILE         AVB RSA-2048 private key. Defaults to the public AOSP test key.
  -h, --help         Show this help.

Auto-detected kernel paths:
  out/arch/arm64/boot/Image.gz
  arch/arm64/boot/Image.gz
  out/arch/arm64/boot/Image
  arch/arm64/boot/Image

Auto-detected DTB paths:
  out/arch/arm64/boot/dts/mediatek/mt6785.dtb
  arch/arm64/boot/dts/mediatek/mt6785.dtb

This script packages an already-built kernel. It does not build the kernel/toolchain.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-boot)
            [[ $# -ge 2 ]] || die "--base-boot needs a file"
            BASE_BOOT="$2"
            shift 2
            ;;
        --kernel)
            [[ $# -ge 2 ]] || die "--kernel needs a file"
            KERNEL_IMAGE="$2"
            shift 2
            ;;
        --dtb)
            [[ $# -ge 2 ]] || die "--dtb needs a file"
            DTB_IMAGE="$2"
            shift 2
            ;;
        --no-dtb)
            NO_DTB=1
            shift
            ;;
        --output)
            [[ $# -ge 2 ]] || die "--output needs a file"
            OUTPUT_IMAGE="$2"
            shift 2
            ;;
        --key)
            [[ $# -ge 2 ]] || die "--key needs a file"
            AVB_KEY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required by avbtool"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

[[ -f "$MKBOOTIMG" ]] || die "Missing $MKBOOTIMG"
[[ -f "$UNPACK_BOOTIMG" ]] || die "Missing $UNPACK_BOOTIMG"
[[ -f "$AVBTOOL" ]] || die "Missing $AVBTOOL"
[[ -f "$AVB_KEY" ]] || die "AVB key not found: $AVB_KEY"

mkdir -p "$STATE_DIR"

if [[ -n "$BASE_BOOT" ]]; then
    [[ -f "$BASE_BOOT" ]] || die "Base boot not found: $BASE_BOOT"
    magic="$(head -c 8 "$BASE_BOOT" || true)"
    [[ "$magic" == "ANDROID!" ]] || die "Not an Android boot image: $BASE_BOOT"
    cp -f -- "$BASE_BOOT" "$TEMPLATE_BOOT"
    echo "Cached boot template: $TEMPLATE_BOOT"
fi

[[ -f "$TEMPLATE_BOOT" ]] || die     "No cached template. First run: bash build_boot_avb.sh --base-boot /path/to/boot.img"

if [[ -z "$KERNEL_IMAGE" ]]; then
    for candidate in         "$ROOT_DIR/out/arch/arm64/boot/Image.gz"         "$ROOT_DIR/arch/arm64/boot/Image.gz"         "$ROOT_DIR/out/arch/arm64/boot/Image"         "$ROOT_DIR/arch/arm64/boot/Image"; do
        if [[ -f "$candidate" ]]; then
            KERNEL_IMAGE="$candidate"
            break
        fi
    done
fi
[[ -n "$KERNEL_IMAGE" && -f "$KERNEL_IMAGE" ]] || die     "Built kernel not found. Pass --kernel /path/to/Image.gz"

if [[ "$NO_DTB" -eq 0 && -z "$DTB_IMAGE" ]]; then
    for candidate in         "$ROOT_DIR/out/arch/arm64/boot/dts/mediatek/mt6785.dtb"         "$ROOT_DIR/arch/arm64/boot/dts/mediatek/mt6785.dtb"; do
        if [[ -f "$candidate" ]]; then
            DTB_IMAGE="$candidate"
            break
        fi
    done
fi

mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(mktemp -d "$STATE_DIR/work.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
UNPACK_DIR="$WORK_DIR/unpacked"
ARGS_FILE="$WORK_DIR/mkbootimg.args"
UNSIGNED_IMAGE="$WORK_DIR/boot-unsigned.img"
mkdir -p "$UNPACK_DIR"

echo "Template : $TEMPLATE_BOOT"
echo "Kernel   : $KERNEL_IMAGE"

# Preserve the template's ramdisk/header/cmdline/offsets exactly and only
# replace the kernel (and DTB when available).
python3 "$UNPACK_BOOTIMG"     --boot_img "$TEMPLATE_BOOT"     --out "$UNPACK_DIR"     --format=mkbootimg     -0 > "$ARGS_FILE"

[[ -f "$UNPACK_DIR/kernel" ]] || die "Template did not contain a kernel section"
cp -f -- "$KERNEL_IMAGE" "$UNPACK_DIR/kernel"

if [[ "$NO_DTB" -eq 0 && -f "$UNPACK_DIR/dtb" ]]; then
    if [[ -n "$DTB_IMAGE" && -f "$DTB_IMAGE" ]]; then
        cp -f -- "$DTB_IMAGE" "$UNPACK_DIR/dtb"
        echo "DTB      : $DTB_IMAGE"
    else
        warn "No newly-built mt6785.dtb found; keeping template DTB. Use --dtb to replace it."
    fi
elif [[ "$NO_DTB" -eq 1 ]]; then
    echo "DTB      : template DTB (--no-dtb)"
fi

declare -a MKBOOTIMG_ARGS=()
while IFS= read -r -d '' arg; do
    MKBOOTIMG_ARGS+=("$arg")
done < "$ARGS_FILE"

[[ "${#MKBOOTIMG_ARGS[@]}" -gt 0 ]] || die "Failed to read mkbootimg arguments"

python3 "$MKBOOTIMG" "${MKBOOTIMG_ARGS[@]}" --output "$UNSIGNED_IMAGE"

cp -f -- "$UNSIGNED_IMAGE" "$OUTPUT_IMAGE"

python3 "$AVBTOOL" add_hash_footer     --image "$OUTPUT_IMAGE"     --partition_name boot     --partition_size "$BOOT_PARTITION_SIZE"     --hash_algorithm "$AVB_HASH_ALGORITHM"     --algorithm "$AVB_ALGORITHM"     --key "$AVB_KEY"     --rollback_index "$AVB_ROLLBACK_INDEX"     --rollback_index_location "$AVB_ROLLBACK_INDEX_LOCATION"

python3 "$AVBTOOL" verify_image     --image "$OUTPUT_IMAGE"     --key "$AVB_KEY"

actual_size="$(stat -c '%s' "$OUTPUT_IMAGE")"
[[ "$actual_size" -eq "$BOOT_PARTITION_SIZE" ]] || die     "Unexpected output size: $actual_size (expected $BOOT_PARTITION_SIZE)"

AVB_INFO="$(python3 "$AVBTOOL" info_image --image "$OUTPUT_IMAGE")"

grep -Eq "Algorithm:[[:space:]]+$AVB_ALGORITHM" <<<"$AVB_INFO" ||     die "AVB algorithm verification failed"
grep -Eq "Rollback Index:[[:space:]]+$AVB_ROLLBACK_INDEX" <<<"$AVB_INFO" ||     die "AVB rollback index verification failed"
grep -Eq "Rollback Index Location:[[:space:]]+$AVB_ROLLBACK_INDEX_LOCATION" <<<"$AVB_INFO" ||     die "AVB rollback-index-location verification failed"
grep -Eq "Partition Name:[[:space:]]+boot" <<<"$AVB_INFO" ||     die "AVB boot partition descriptor verification failed"

echo
echo "AVB parameters:"
echo "  partition size          : $BOOT_PARTITION_SIZE"
echo "  algorithm               : $AVB_ALGORITHM"
echo "  hash algorithm          : $AVB_HASH_ALGORITHM"
echo "  rollback index          : $AVB_ROLLBACK_INDEX"
echo "  rollback index location : $AVB_ROLLBACK_INDEX_LOCATION"
echo
echo "Output:"
echo "  $OUTPUT_IMAGE"
sha256sum "$OUTPUT_IMAGE"
