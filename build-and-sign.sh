#!/bin/bash
# build-and-sign.sh -- the whole path, detached, with a VERDICT file.
#
#   setsid nohup bash ~/itel_rs4_Crdroid/build-and-sign.sh > /dev/null 2>&1 < /dev/null &
#   (it prints its run dir first; poll <run>/VERDICT, never the PID: setsid forks)
#
#   SIGN=1   release-sign after the build (sign-release.sh: sign_target_files_apks -d $KEYS,
#            default ~/rs4-release-keys, then ota_from_target_files). Only for VARIANT=user and never
#            with WITH_ADB_INSECURE; the verdict's artifact is then the SIGNED zip.
#   Every rom-build.sh variable (TOP, OUT_TARGET, PRODUCT, RELEASE, VARIANT, GOAL, DIRTY_OK)
#   passes through.
#   WITH_ADB_INSECURE=true   LineageOS's switch (vendor/lineage/config/common.mk): ro.debuggable=1,
#            adb on at boot, NO authorisation. For bring-up on a phone with no usable screen only:
#            the zip is renamed *-BRINGUP-ADBINSECURE.zip and must never be released.
#            Without it, userdebug = ro.debuggable=0 + ro.adb.secure=1 (adb off on a fresh /data).
#            Either way the built props are checked against the mode asked for.
#
# WHY (crDroid recipe, 08-19 / 08-28): the steps were correct on paper and nowhere
# executable, and a build ran on a tree that no longer matched git. So verification comes
# first and the script REFUSES to build when it fails. Any exit leaves a verdict: silence
# must never read as success.
set -u
TOP="${TOP:-/mnt/Data/lineage-23.2}"
REC="${REC:-$(cd "$(dirname "$0")" && pwd)}"
. "$REC/rom.conf" || exit 2
export TOP
SIGN="${SIGN:-0}"

RUN="$TOP/tmp-release/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN" || exit 2
D="$RUN/driver.log"; V="$RUN/VERDICT"; B="$RUN/build.log"
say(){ echo ">>> $*" | tee -a "$D"; }
die(){ echo "FAIL $1" > "$V"; say "VERDICT FAIL $1"; exit 1; }
trap '[ -s "$V" ] || { echo "FAIL unexpected-exit" > "$V"; say "VERDICT FAIL unexpected-exit"; }' EXIT

echo "$RUN"
say "RUN $RUN"
say "START $(date -u +%FT%TZ)"
if [ "$SIGN" = 1 ]; then
  [ -z "${WITH_ADB_INSECURE:-}" ] || die "SIGN=1 with WITH_ADB_INSECURE: a bring-up build is never release-signed"
  [ "${VARIANT:-userdebug}" = user ] || die "SIGN=1 needs VARIANT=user (got ${VARIANT:-userdebug})"
  [ -d "${KEYS:-$HOME/rs4-release-keys}" ] || die "SIGN=1 but no key directory ${KEYS:-$HOME/rs4-release-keys}"
fi

say "STAGE verify-sync"
bash "$REC/tools/verify-sync.sh" > "$RUN/verify-sync.log" 2>&1 \
  || { say "$(grep '^FAIL' "$RUN/verify-sync.log" | tr '\n' '|')"; die "verify-sync"; }
say "verify-sync OK"

say "STAGE apply-overlays"
bash "$REC/apply-overlays.sh" "$TOP" > "$RUN/overlays.log" 2>&1 || {
  say "TAIL: $(grep -E 'FATAL' "$RUN/overlays.log" | tail -2 | tr '\n' '|')"; die "apply-overlays"; }
say "apply-overlays OK"

# Trust BOTH the exit status and the printed BUILD_RC.
say "STAGE build"
bash "$REC/rom-build.sh" > "$B" 2>&1
BRC=$?
IRC=$(grep -oE '^BUILD_RC=[0-9]+' "$B" | tail -1 | cut -d= -f2)
say "BUILD_RC=$BRC inner=${IRC:-none}"
if [ "$BRC" -ne 0 ] || [ "${IRC:-1}" != "0" ]; then
  say "TAIL: $(grep -E 'FATAL|FAILED:|ninja: error|error:|LUNCH_FAILED' "$B" | tail -3 | tr '\n' '|')"
  die "build rc=$BRC inner=${IRC:-none}"
fi

OUTP="$TOP/out/target/product/S666LN"
Z=$(ls -t "$OUTP"/$ROM_ARTIFACT_GLOB 2>/dev/null | head -1)
[ -n "$Z" ] || die "artifact-not-found in $OUTP"

# The adb mode, from the built props (load order system -> system_ext -> vendor -> product;
# a later file overrides an earlier one, so the last value is the one init keeps). AICP's
# gen_build_prop.py writes ro.adb.secure=1 into every userdebug system/build.prop; the switch's 0
# lives in system_ext and wins at runtime. persist.sys.usb.config is informational: init's
# update_sys_usb_config() appends adb at boot whenever the effective ro.adb.secure is 0.
getp(){ cat "$OUTP/system/build.prop" "$OUTP/system_ext/etc/build.prop" "$OUTP/vendor/build.prop" \
  "$OUTP/product/etc/build.prop" 2>/dev/null | grep "^$1=" | tail -1 | cut -d= -f2-; }
ADBSEC=$(getp ro.adb.secure); DBG=$(getp ro.debuggable); USBC=$(getp persist.sys.usb.config)
say "PROPS ro.adb.secure=$ADBSEC ro.debuggable=$DBG persist.sys.usb.config=$USBC"
if [ -n "${WITH_ADB_INSECURE:-}" ]; then
  [ "$ADBSEC" = 0 ] && [ "$DBG" = 1 ] \
    || die "WITH_ADB_INSECURE set but the image is not insecure+debuggable"
  # bacon hard-links the OTA package to its version name: EVERY top-level name of this file
  # gets the suffix, or the insecure image stays behind under a release-looking name.
  for f in $(find "$OUTP" -maxdepth 1 -name '*.zip' -samefile "$Z"); do
    case "$f" in *-BRINGUP-ADBINSECURE.zip) ;; *)
      mv "$f" "${f%.zip}-BRINGUP-ADBINSECURE.zip" || die "bringup-rename $f";; esac
  done
  case "$Z" in *-BRINGUP-ADBINSECURE.zip) ;; *) Z="${Z%.zip}-BRINGUP-ADBINSECURE.zip";; esac
  [ -z "$(find "$OUTP" -maxdepth 1 -name '*.zip' -samefile "$Z" ! -name '*-BRINGUP-ADBINSECURE.zip')" ] \
    || die "bringup-rename: an unsuffixed name of the insecure image remains"
  say "BRINGUP build: adb without authorisation. NEVER RELEASE."
else
  [ "$ADBSEC" = 1 ] || die "ro.adb.secure=$ADBSEC without WITH_ADB_INSECURE (residue of a bring-up build?)"
fi

if [ "$SIGN" = 1 ]; then
  [ "$(getp ro.build.type)" = user ] && [ "$DBG" = 0 ] || die "SIGN=1 but the image is not user + ro.debuggable=0"
  say "STAGE sign (unsigned test-keys artifact kept: $Z)"
  # Date AND time: two builds on one UTC day must never share a name (build 20 vs 21, 11-16).
  SNAME="${ROM_SIGNED_PREFIX}-$(date -u +%Y%m%d-%H%M)-signed"
  TOP="$TOP" bash "$REC/sign-release.sh" "$SNAME" > "$RUN/sign.log" 2>&1 \
    || { say "TAIL: $(tail -4 "$RUN/sign.log" | tr '\n' '|')"; die "sign"; }
  Z="$OUTP/$SNAME.zip"
  [ -f "$Z" ] || die "signed artifact missing: $Z"
  say "SIGNED: $(grep -E 'signer DN|OK: signed' "$RUN/sign.log" | tr -s ' ' | tr '\n' '|')"
fi
say "ARTIFACT $Z  $(stat -c %s "$Z") B"
say "SHA256 $(sha256sum "$Z" | cut -d' ' -f1)"
echo "OK artifact=$Z" > "$V"
say "VERDICT OK $(date -u +%FT%TZ)"
