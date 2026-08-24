#!/bin/bash
# crDroid 13.0 RC — honest stock identity + release-keys + user variant.
#
# Differs from crdroid-build.sh in exactly two ways:
#   * lunch target is -user (not -userdebug) -> ro.build.type=user, no adb root
#   * BUILD_NUMBER is pinned to the stock incremental so
#     ro.build.version.incremental reads 251212V1661 instead of a timestamp.
# Everything else (identity, signing, sepolicy, GApps) comes from apply-overlays.sh,
# which MUST have been run against this tree first.
#
# WHY THIS BUILDS target-files-package AND NOT bacon
#   `bacon` produces an UNSIGNED, dev-keys OTA and then DELETES the target-files it just built
#   (vendor/lineage/build/tasks/bacon.mk ends with
#      rm -rf $(call intermediates-dir-for,PACKAGING,target_files)),
#   leaving nothing for sign_target_files_apks to sign. The shippable artifact comes from
#   sign-release.sh, which builds its own OTA from the SIGNED target-files -- so bacon's OTA is
#   pure waste (~10 min of payload generation thrown away). Build the target-files, then sign.
#
# FULL RELEASE FLOW:
#   1. bash ~/itel_rs4_Crdroid/apply-overlays.sh ~/crdroid
#   2. bash ~/crdroid-build-rc.sh                 (this script)
#   3. bash ~/itel_rs4_Crdroid/sign-release.sh    (-> crDroidAndroid-...-signed.zip)
export PATH=$HOME/bin:$PATH
export USE_CCACHE=1
# Overridable, same ${VAR:-default} convention sign-release.sh already uses for TOP.
# The default is only safe where $HOME has room: on the local build box $HOME is on
# / with ~52 GB free, so `ccache -M 50G` there fills the root filesystem. Point
# CCACHE_DIR at the build disk instead. 2026-08-17, when the VM went away.
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
ccache -M "${CCACHE_SIZE:-50G}" >/dev/null 2>&1

# ro.build.version.incremental. The build otherwise substitutes a unix timestamp,
# which is what produced the bogus ".../1785172498:user/release-keys" fingerprint.
# It also sets FILE_NAME_TAG, so the target-files is named ...-251212V1661 rather than
# ...-eng.nobody (crDroid pins BUILD_USERNAME := nobody).
export BUILD_NUMBER=251212V1661

# ro.rs4.build.stamp -- what PackageManager compares to decide "is this an update?"
#
# ro.build.version.incremental is pinned to the stock identity above, which is
# exactly what AOSP's upgrade test compares, so mIsUpgrade is permanently false
# and dexopt profiles, app profiles, new system apps, code-cache clearing and
# privapp permission changes are all dead on this ROM. device/itel/S666LN's
# device.mk turns this into ro.rs4.build.stamp and the frameworks/base patch
# reads it; the reported identity is untouched.
#
# ⚠ SET ONCE, HERE, PER RELEASE BUILD -- not in device.mk. Generated inside the
# build it would change on every incremental `m` and make EVERY boot look like an
# upgrade, which re-runs a permission regrant and clears every package's code
# cache each time. One value per release, shared by every artifact in it.
export RS4_BUILD_STAMP="$(date -u +%Y%m%d%H%M%S)"
echo "== RS4_BUILD_STAMP=${RS4_BUILD_STAMP}"

cd "${TOP:-$HOME/crdroid}" || exit 2

# Guards: the RC is meaningless if the overlays were not applied.
grep -q "vendor/crdroid-keys/releasekey" device/itel/S666LN/device.mk 2>/dev/null || {
  echo "FATAL: signing not configured — run apply-overlays.sh first"; exit 3; }
grep -q "TP1A.220624.014" build/make/core/build_id.mk 2>/dev/null || {
  echo "FATAL: BUILD_ID not set to stock — run apply-overlays.sh first"; exit 3; }
# sign_target_files_apks asserts the last token of ro.build.description ends in "-keys"; crDroid
# reduces the whole string to $(BUILD_ID), which makes the tree unsignable. apply-overlays step 14.
grep -q "^BUILD_DESC" device/itel/S666LN/BoardConfig.mk 2>/dev/null || {
  echo "FATAL: BUILD_DESC not set — signing would fail at RewriteProps; run apply-overlays.sh"; exit 3; }

source build/envsetup.sh
lunch lineage_S666LN-user || { echo "LUNCH_FAILED"; exit 2; }
date "+BUILD_START %F %T"
mka target-files-package
rc=$?
echo "BUILD_RC=$rc"
date "+BUILD_END %F %T"
ls -la out/target/product/S666LN/obj/PACKAGING/target_files_intermediates/*.zip 2>/dev/null
[ "$rc" -eq 0 ] && echo "NEXT: bash ~/itel_rs4_Crdroid/sign-release.sh"
