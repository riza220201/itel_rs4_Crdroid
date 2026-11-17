#!/bin/bash
# rom-build.sh -- build the ROM in rom.conf (crDroid 16) for the itel RS4 (the 14 GiB home box, or a
# rented build server). The AICP recipe's aicp-build.sh with the ROM-specific values moved to rom.conf.
#
#   TOP=/mnt/Data/lineage-23.2            source tree
#   OUT_TARGET=/mnt/external_nvme/crdroid16-out   where $TOP/out (a symlink) points; see OUT below.
#                                         OUT_TARGET=$TOP/out = a real out dir in the tree
#   PRODUCT/RELEASE/GOAL default to rom.conf (lineage_S666LN, bp4a, otapackage)   VARIANT=userdebug
#   DIRTY_OK=1                            build an uncommitted device tree (loud; never for a release)
#   KEEP_GOING=1                          m -k: build everything not behind a failure and report ALL
#                                         walls in one run (a first build's walls are independent)
#   REQUIRE_JAMESDSP=1                    refuse to build without the JamesDSP control app (see below)
#   JOBS=N                                m -jN (default: soong's own, nproc+2). On a SHARED server
#                                         set it: nproc there counts every tenant's cores, and the
#                                         per-user cgroup memory cap is what a -j192 link storm hits
#
# apply-overlays.sh MUST have been run against TOP first (build-and-sign.sh does both).
#
# GOAL: NOT bacon on crDroid (rom.conf ROM_GOAL says why: its bacon.mk rm -rf's the target-files
# release signing needs). Other ROMs' bacon only hard-links the OTA package; it does NOT rm -rf the target-files
# (lineage-20's bacon.mk did, which is why the crDroid recipe built target-files-package).
#
# OUT: /mnt/Data holds the source (155 GB free after the sync); one A16 out was estimated at
# 130-180 GB (estimate of 2026-11-12), which leaves no margin there. /mnt/external_nvme (USB NVMe,
# ext4) had 256 GB free on 11-13. So the out dir lives there -- but as $TOP/out, a SYMLINK,
# with OUT_DIR left at its default. An absolute OUT_DIR outside the tree breaks soong:
#   platform_testing/Android.bp:728 "continuous_instrumentation_metric_tests": Path is outside
#   directory: /mnt/external_nvme/aicp-out/host/linux-x86/bin/perfetto_trace_processor_shell
# because build/soong/ci_tests/ci_test_package_zip.go:300 skips host files only when their path
# starts with "out" (it assumes OUT_DIR=out). Soong resolves a symlinked out itself
# (ui/build/sandbox_linux.go EvalSymlinks(outDir)).
#
# Every preflight below has cost a real build before (build-system gotchas,
# crDroid build-and-sign.sh, Advan 09-29).
set -u
TOP="${TOP:-/mnt/Data/lineage-23.2}"
REC="$(cd "$(dirname "$0")" && pwd)"
OUT_TARGET="${OUT_TARGET:-/mnt/external_nvme/crdroid16-out}"
unset OUT_DIR OUT_DIR_COMMON_BASE
REC_CONF="$(cd "$(dirname "$0")" && pwd)/rom.conf"
. "$REC_CONF" || { echo "FATAL: no $REC_CONF"; exit 3; }
PRODUCT="${PRODUCT:-$ROM_PRODUCT}"
RELEASE="${RELEASE:-$ROM_RELEASE}"
VARIANT="${VARIANT:-userdebug}"
GOAL="${GOAL:-${ROM_GOAL:-bacon}}"
DT="$TOP/device/itel/S666LN"

die(){ echo "FATAL: $*"; exit 3; }
cd "$TOP" || exit 2

echo "== preflight"
# soong holds the whole module graph: ~40-47 GB working set on a 14 GiB host (A16 AOSPA),
# OOM-killed at 8.76 GiB without swap, and misreported as "bootstrap failed".
# The gate is what the build can really use: available RAM, capped by any cgroup memory.max
# on the way up from this process (a shared server caps each user), plus free swap.
# On the home box /swapfile_compile is not in fstab: a power cut drops it silently.
if [ -e /swapfile_compile ]; then
  grep -q '^/swapfile_compile ' /proc/swaps || die "/swapfile_compile is not active (not in fstab): sudo swapon /swapfile_compile"
fi
MEM=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
cg=/sys/fs/cgroup$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
while [ "${cg#/sys/fs/cgroup}" != "$cg" ] && [ "$cg" != /sys/fs/cgroup ]; do
  if [ -r "$cg/memory.max" ] && [ "$(cat "$cg/memory.max")" != max ]; then
    left=$(( ( $(cat "$cg/memory.max") - $(cat "$cg/memory.current") ) / 1073741824 ))
    [ "$left" -lt "$MEM" ] && MEM=$left
  fi
  cg=$(dirname "$cg")
done
SWAP=$(awk '/SwapFree/{print int($2/1048576)}' /proc/meminfo)
[ $(( ${MEM:-0} + ${SWAP:-0} )) -ge 50 ] || die "only ${MEM} GiB RAM + ${SWAP} GiB swap usable; soong's graph needs ~50+ GiB"

if [ "$OUT_TARGET" = "$TOP/out" ]; then
  # A host with room on the tree's own filesystem (the rented server): a real
  # $TOP/out, which remote execution (RBE) wants inside its exec root anyway.
  [ -L "$TOP/out" ] && die "$TOP/out is a symlink, but OUT_TARGET=$TOP/out asks for a real directory"
  mkdir -p "$TOP/out" || die "cannot create $TOP/out"
elif ! mkdir -p "$OUT_TARGET"; then
  die "cannot create $OUT_TARGET"
elif [ -L "$TOP/out" ]; then
  [ "$(readlink -f "$TOP/out")" = "$(readlink -f "$OUT_TARGET")" ] || die "$TOP/out points at $(readlink -f "$TOP/out"), not $OUT_TARGET"
elif [ -e "$TOP/out" ]; then
  die "$TOP/out is a real directory; move it and make it a symlink to $OUT_TARGET"
else
  ln -s "$OUT_TARGET" "$TOP/out"
fi
FREE=$(df -BG --output=avail "$OUT_TARGET" | tail -1 | tr -dc 0-9)
if [ -d "$OUT_TARGET/soong" ]; then NEED=40; else NEED=200; fi
[ "${FREE:-0}" -ge "$NEED" ] || die "only ${FREE} GB free for the out dir $OUT_TARGET (need ${NEED} for a $( [ $NEED = 200 ] && echo fresh || echo warm) out)"

# Host tools the tree's makefiles shell out to at PARSE time -- a missing one costs a whole
# analysis before kati says so (analysis-7: vendor/aicp/bootanimation/Android.mk:64 "stop",
# ImageMagick's mogrify generates AICP's boot animation). Debian: apt install imagemagick.
for t in $ROM_HOST_TOOLS; do command -v "$t" >/dev/null || die "host tool $t is not installed ($ROM_NAME's makefiles need it)"; done

# a sync and a build on one tree: the build reads a half-updated source
( exec 9>"$TOP/.sync.lock"; flock -n 9 ) || die "a repo sync holds $TOP/.sync.lock"

# 08-18: chromium-webview synced as empty LFS pointers once
for a in arm arm64; do
  [ "$(stat -c %s "external/chromium-webview/prebuilt/$a/webview.apk" 2>/dev/null || echo 0)" -gt 1000000 ] \
    || die "external/chromium-webview/prebuilt/$a/webview.apk is not a payload (git lfs pull there)"
done

# the local manifest the tree was synced with is the recipe's
cmp -s "$REC/local_manifests/S666LN.xml" .repo/local_manifests/S666LN.xml \
  || die ".repo/local_manifests/S666LN.xml differs from the recipe's local_manifests/S666LN.xml"

# the tree soong reads is the tree we commit to (crDroid 08-19/08-28: a build carried work that
# had been reverted in git). device/itel/S666LN is a git worktree of the one device repo.
[ "$(git -C "$DT" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "lineage-23.2" ] || die "$DT is not on branch lineage-23.2"
if [ -n "$(git -C "$DT" status --porcelain)" ]; then
  [ "${DIRTY_OK:-0}" = 1 ] || die "$DT has uncommitted changes (commit them, or DIRTY_OK=1 for a throwaway test)"
  echo "🔴 DIRTY_OK=1: building UNCOMMITTED device-tree changes; this build is not reproducible"
fi
[ -d vendor/itel/S666LN ] || die "vendor/itel/S666LN is missing (vendor tree not generated yet)"
# JamesDSP's control app is BUILD OUTPUT of the device tree's tools/build-jamesdsp.sh (gitignored). Without it
# device.mk's guard silently ships AudioFX instead: the first Axion build (2026-11-17) came out without
# JamesDSP that way. A release build asks for it with REQUIRE_JAMESDSP=1.
JD="$DT/prebuilts/JamesDSP"
if [ -s "$JD/JamesDSP.apk" ] && [ -s "$JD/Android.bp" ]; then
  echo "   JamesDSP control app: present, apk sha256 $(sha256sum "$JD/JamesDSP.apk" | cut -c1-16)"
else
  [ "${REQUIRE_JAMESDSP:-0}" = 1 ] && die "REQUIRE_JAMESDSP=1 but $JD lacks JamesDSP.apk + Android.bp (run the device tree's tools/build-jamesdsp.sh)"
  echo "   JamesDSP control app: ABSENT -> AudioFX ships (device.mk guard)"
fi
echo "   RAM ${MEM} + swap ${SWAP} GiB usable, out -> $OUT_TARGET ${FREE} GB free, webview ok, manifest ok"
echo "   device tree $(git -C "$DT" rev-parse --short HEAD) $(git -C "$DT" log -1 --format=%s | cut -c1-70)"

# envsetup.sh and lunch read unset variables (ANDROID_GLOBAL_BUILD_PATHS, ...): no set -u past here.
set +u
# Axion's envsetup.sh runs setup_keys -> `gk -s` whenever vendor/lineage-priv/keys is absent, and does it
# BEFORE it exports ANDROID_KEY_PATH. In a clean shell that path is empty, every write fails, nothing is
# made (2026-11-17, first Axion build). In a shell that already carries ANDROID_KEY_PATH it would generate
# AxionOS keys and a keys.mk making them the build's dev certificate: keys we do not hold, and which
# sign_target_files_apks -d (test cert -> ours) leaves in place. Never inherit it; check the result below.
unset ANDROID_KEY_PATH
source build/envsetup.sh
if type rom_lunch >/dev/null 2>&1; then
  rom_lunch "$VARIANT" || { echo "LUNCH_FAILED"; exit 2; }
else
  lunch "${PRODUCT}-${RELEASE}-${VARIANT}" || { echo "LUNCH_FAILED"; exit 2; }
fi
[ "$TARGET_PRODUCT" = "$PRODUCT" ] && [ "$TARGET_RELEASE" = "$RELEASE" ] && [ "$TARGET_BUILD_VARIANT" = "$VARIANT" ] \
  || { echo "LUNCH_FAILED: got $TARGET_PRODUCT-$TARGET_RELEASE-$TARGET_BUILD_VARIANT, want $PRODUCT-$RELEASE-$VARIANT"; exit 2; }
echo "   identity: S666LN_IDENTITY=${S666LN_IDENTITY:-<tree default>}"
# Release signing maps the AOSP test certificates onto ours; a build signed with anything else would
# keep that signer. Refuse before the build, not after it (sign-release's DN check would, an hour later).
DEVCERT=$(get_build_var DEFAULT_SYSTEM_DEV_CERTIFICATE 2>/dev/null)
[ "$DEVCERT" = build/make/target/product/security/testkey ] && [ ! -e vendor/lineage-priv/keys ] \
  || { echo "FATAL: dev certificate is '$DEVCERT'$( [ -e vendor/lineage-priv/keys ] && echo ' and vendor/lineage-priv/keys exists'): the build would not be signed with the test keys our release signing replaces"; exit 3; }
echo "   dev certificate: $DEVCERT (replaced by release signing)"
date "+BUILD_START %F %T"
J=${JOBS:+-j$JOBS}
# GOAL may name several targets (crDroid: target-files-package otapackage): split on purpose.
# shellcheck disable=SC2086
if [ "${KEEP_GOING:-0}" = 1 ]; then echo "KEEP_GOING=1: m -k $J $GOAL"; m $J -k $GOAL; else m $J $GOAL; fi
rc=$?
echo "BUILD_RC=$rc"
date "+BUILD_END %F %T"
[ "$rc" -eq 0 ] && ls -la "$TOP/out/target/product/S666LN/"*.zip 2>/dev/null
exit $rc
