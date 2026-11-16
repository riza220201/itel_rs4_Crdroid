#!/bin/bash
# ⛔ SUPERSEDED 11-13: generic products are a dead end in this tree, the A16
# vendor libs come from our device build, and this script still uses an absolute OUT_DIR, which
# soong rejects (see aicp-build.sh OUT). Kept as the record of what was tried.
#
# tools/build-a16-vendor-libs.sh -- build the A16 vendor variants of every library in AOSP's v31
# VNDK snapshot, on a device-independent generic product ($GENERIC), and collect them in one directory.
#
#   TOP=/mnt/Data/lineage-23.2   OUT_DIR=/mnt/external_nvme/aicp-out
#   -> $OUT_DIR/a16-vendor-libs/{lib,lib64}/   + RESULT (OK / FAIL <why>)
#
# WHY: route L (decided 2026-11-13) puts A16's own vendor variants of the former-VNDK libs
# in /vendor/lib* and gives a stock A12 blob a `-v31` copy only where A16 broke it. Which blobs
# that is, is measured by the device tree's tools/v31-delta-check.py with
#     <stock vendor> <A16 libs (this output)> <v31 libs (prebuilts/vndk/v31)>
# Check A = symbols v31 exports and A16 does not, referenced by a stock ELF (a hard break);
# Check B = libraries v31 has and A16 does not build at all. The libraries only depend on the
# arch, not on the device, so a generic product gives the same exports our device build will --
# before our vendor tree exists.
set -u
TOP="${TOP:-/mnt/Data/lineage-23.2}"
export OUT_DIR="${OUT_DIR:-/mnt/external_nvme/aicp-out}"
DEST="$OUT_DIR/a16-vendor-libs"
R="$DEST/RESULT"
mkdir -p "$DEST"; rm -f "$R"
fail(){ echo "FAIL $*" | tee "$R"; exit 1; }
# The device tree imports the vendor/itel/S666LN soong namespace, and soong parses every
# Android.bp whatever the product: until the vendor tree exists, analysis of ANY product stops on
# "namespace vendor/itel/S666LN does not exist". This build needs no device file, so hide
# device/itel for its duration only (soong's Finder marker; removed on any exit).
HIDE=""
if [ ! -d "$TOP/vendor/itel/S666LN" ] && [ ! -e "$TOP/device/itel/.find-ignore" ]; then
  HIDE="$TOP/device/itel/.find-ignore"; : > "$HIDE"
  echo "device/itel hidden for this build (no vendor tree yet)"
fi
trap '[ -n "$HIDE" ] && rm -f "$HIDE"; [ -s "$R" ] || echo "FAIL unexpected-exit" > "$R"' EXIT

grep -q '^/swapfile_compile ' /proc/swaps || fail "/swapfile_compile not active"
SWAP=$(awk '/SwapFree/{print int($2/1048576)}' /proc/meminfo)
[ "$SWAP" -ge 40 ] || fail "only ${SWAP} GiB swap free"

V31="$TOP/prebuilts/vndk/v31/arm64/arch-arm64-armv8-a/shared"
NAMES=$(ls "$V31/vndk-core" "$V31/vndk-sp" | sed -n 's/\.so$//p' | sort -u)
echo "v31 snapshot: $(echo "$NAMES" | wc -l) libraries"

cd "$TOP" || exit 2
# envsetup.sh and lunch read unset variables (ANDROID_GLOBAL_BUILD_PATHS, ...): no set -u past here.
set +u
source build/envsetup.sh
# Not aosp_arm64 nor lineage_gsi_arm64: both set PRODUCT_SOONG_DEFINED_SYSTEM_IMAGE :=
# aosp_system_image, whose deps (build/make/target/product/gsi/Android.bp:177) name AOSP's
# "Calendar" -- no such module in this tree (Lineage ships Etar) -> "depends on undefined module".
GENERIC="${GENERIC:-lineage_sdk_phone_arm64}"
lunch "$GENERIC-bp4a-userdebug" || fail "lunch $GENERIC"
POUT=$(get_build_var PRODUCT_OUT)
date "+ANALYSIS_START %F %T"
m module-info || fail "m module-info"
MI="$POUT/module-info.json"
[ -s "$MI" ] || fail "no $MI"

# Which of the v31 names A16 still builds a vendor variant of. The rest are Check B by definition.
echo "$NAMES" > "$DEST/v31-names.txt"
python3 -I - "$MI" "$DEST/v31-names.txt" "$DEST" <<'PY' || fail "module-info parse"
import json, sys
mi = json.load(open(sys.argv[1]))
names = open(sys.argv[2]).read().split()
have, gone = [], []
for n in names:
    m = mi.get(n + ".vendor")
    (have if m and any("/vendor/" in p for p in m.get("installed", [])) else gone).append(n)
open(sys.argv[3] + "/a16-has.txt", "w").write("\n".join(have) + "\n")
open(sys.argv[3] + "/a16-lacks.txt", "w").write("\n".join(gone) + "\n")
print(f"A16 builds a vendor variant of {len(have)}; lacks {len(gone)}")
PY
date "+BUILD_START %F %T"
m $(sed 's/$/.vendor/' "$DEST/a16-has.txt") || fail "m <.vendor libs>"
date "+BUILD_END %F %T"

P="$POUT/vendor"
for d in lib lib64; do
  mkdir -p "$DEST/$d"
  while read -r n; do
    [ -f "$P/$d/$n.so" ] && cp -f "$P/$d/$n.so" "$DEST/$d/"
  done < "$DEST/a16-has.txt"
done
echo "collected: lib64 $(ls "$DEST/lib64" | wc -l), lib $(ls "$DEST/lib" | wc -l)"
echo "OK $(ls "$DEST/lib64" | wc -l) lib64 / $(ls "$DEST/lib" | wc -l) lib" > "$R"
