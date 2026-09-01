#!/bin/bash
# build-and-sign.sh  —  the whole release path, detached, with a verdict file.
#
#   setsid nohup bash ~/itel_rs4_Crdroid/build-and-sign.sh > /dev/null 2>&1 &
#
#   SKIP_BUILD=1 ...                 re-sign an ALREADY-BUILT target-files. For
#                                    resuming after signing was interrupted (a
#                                    power cut did exactly this on 2026-08-28).
#                                    Verify the target-files zip with `unzip -t`
#                                    first -- an unclean shutdown is the one time
#                                    the artifact itself may be damaged.
#
# WHY THIS EXISTS
#   The steps were correct in four journals and nowhere executable. Two proven
#   fixes were lost on 2026-08-19 because nobody ran tree-sync-check.sh, and on
#   2026-08-28 the build tree was still carrying REVERTED r54p1 work — the git
#   repos had been reverted and pushed, the tree soong reads had not. Both are
#   pre-flight failures, so pre-flight is step 0 here and the script REFUSES to
#   build if it fails.
#
#   RESUME section 10: long-running work must be setsid-detached, and a watcher
#   needs two halves — a detached one that writes a log and a VERDICT file and
#   survives anything, plus something session-bound that blocks on the verdict.
#   This is the detached half. VERDICT is the artifact; the PID is not.
set -u
TOP="${TOP:-/mnt/external_nvme/crdroid}"
SRC="${SRC:-$HOME/itel-rs4-devicetree/device_itel_S666LN}"
REC="${REC:-$HOME/itel_rs4_Crdroid}"
export TOP
export CCACHE_DIR="${CCACHE_DIR:-/mnt/external_nvme/ccache}"
export CCACHE_SIZE="${CCACHE_SIZE:-50G}"
export PATH="$HOME/bin:$PATH"

RUN="$TOP/tmp-release/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN" || exit 2
D="$RUN/driver.log"; V="$RUN/VERDICT"; B="$RUN/build.log"; S="$RUN/sign.log"
say(){ echo ">>> $*" | tee -a "$D"; }
die(){ echo "FAIL $1" > "$V"; say "VERDICT FAIL $1"; exit 1; }
# Any exit at all still leaves a verdict. Silence must never read as success.
trap '[ -s "$V" ] || { echo "FAIL unexpected-exit" > "$V"; say "VERDICT FAIL unexpected-exit"; }' EXIT

echo "$RUN"                      # so the caller knows where to look
say "RUN $RUN"
say "START $(date -u +%FT%TZ)"

# ---- step 0: pre-flight. Each of these has cost a real build. -------------
say "STAGE preflight"
SWAP=$(awk '/SwapFree/{print int($2/1048576)}' /proc/meminfo)
[ "${SWAP:-0}" -ge 8 ] || die "preflight-swap-only-${SWAP}GiB (soong peaks 8.76 GiB and gets OOM-killed)"
FREE=$(df -BG --output=avail "$TOP" | tail -1 | tr -dc 0-9)
[ "${FREE:-0}" -ge 60 ] || die "preflight-disk-only-${FREE}GiB-on-build-disk"
CL="$TOP/prebuilts/clang/host/linux-x86/clang-3289846/lib64"
[ -e "$CL/libncurses.so.5" ] && [ -e "$CL/libtinfo.so.5" ] || die "preflight-ncurses5-shims-missing (RenderScript's 2016 clang needs them)"
for a in arm arm64; do
  [ -s "$TOP/external/chromium-webview/prebuilt/$a/webview.apk" ] || die "preflight-webview-lfs-$a-empty (git reset --hard in that sub-project)"
done
say "preflight OK  swap=${SWAP}GiB disk=${FREE}GiB shims=yes webview=yes"

SKIP_BUILD="${SKIP_BUILD:-0}"
if [ "$SKIP_BUILD" = "1" ]; then
  # Say it loudly. A resumed run is NOT a gated run, and the log must not let
  # anyone read it as one later.
  say "🔴 SKIP_BUILD=1 -- reusing an existing target-files."
  say "🔴 tree-sync and apply-overlays are SKIPPED: the artifact is already built,"
  say "🔴 so the tree's current state cannot affect it. This run proves nothing"
  say "🔴 about whether the tree and the artifact agree."
fi

# ---- step 1: THE TREE THE COMPILER READS IS NOT THE TREE YOU COMMIT TO ----
if [ "$SKIP_BUILD" != "1" ]; then
say "STAGE tree-sync"
bash "$SRC/tools/tree-sync-check.sh" > "$RUN/tree-sync.log" 2>&1
grep -q '^drifted        : 0' "$RUN/tree-sync.log" || {
  say "DRIFT: $(grep '^  DRIFT' "$RUN/tree-sync.log" | tr '\n' ' ')"
  die "tree-sync-drift (copy each DRIFT file into $TOP/device/itel/S666LN, then re-run)"; }
say "tree-sync OK (drifted 0)"

# ---- step 2: recipe ------------------------------------------------------
say "STAGE apply-overlays"
bash "$REC/apply-overlays-v2.sh" "$TOP" > "$RUN/overlays.log" 2>&1 || die "apply-overlays rc=$?"
grep -q 'FATAL' "$RUN/overlays.log" && die "apply-overlays-FATAL"
say "apply-overlays OK"

# ---- step 3: build. Trust BOTH the exit status and the printed BUILD_RC. --
say "STAGE build"
bash "$REC/crdroid-build-rc.sh" > "$B" 2>&1
BRC=$?
IRC=$(grep -oE '^BUILD_RC=[0-9]+' "$B" | tail -1 | cut -d= -f2)
say "BUILD_RC=$BRC inner=${IRC:-none}"
if [ "$BRC" -ne 0 ] || [ "${IRC:-1}" != "0" ]; then
  say "TAIL: $(grep -E 'FAILED:|ninja: error|FATAL|error:' "$B" | tail -3 | tr '\n' '|')"
  die "build rc=$BRC inner=${IRC:-none}"
fi
fi   # end of SKIP_BUILD guard

# ---- step 4: sign --------------------------------------------------------
say "STAGE sign"
bash "$REC/sign-release.sh" > "$S" 2>&1 || {
  say "TAIL: $(grep -iE 'error|fatal' "$S" | tail -3 | tr '\n' '|')"; die "sign rc=$?"; }
say "SIGN_RC=0"

Z=$(ls -t "$REC"/out-zips/*signed.zip "$TOP"/out/target/product/S666LN/*signed.zip 2>/dev/null | head -1)
[ -n "$Z" ] || die "artifact-not-found"
say "ARTIFACT $Z  $(stat -c %s "$Z") B"
say "SHA256 $(sha256sum "$Z" | cut -d' ' -f1)"
echo "OK artifact=$Z" > "$V"
say "VERDICT OK $(date -u +%FT%TZ)"
say "NEXT: copy to buildNN-... (every build OVERWRITES this filename), then"
say "      verify the SIGNED target-files, then accept.sh on hardware."
