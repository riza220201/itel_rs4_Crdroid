#!/bin/bash
#
# apply-overlays.sh <TREE_PATH>
#
# ROM CONFIGURATION ONLY. Idempotent crDroid 16.0 / itel RS4 (S666LN) recipe,
# derived from the AICP w16.2 recipe (riza220201/itel_rs4_AICP): steps 1-6 are its, unchanged.
# Re-run after any `repo sync`. Each step is guarded so re-running is safe.
#
# WHAT BELONGS HERE, AND WHAT DOES NOT (as in the crDroid recipe)
#   Device facts live in the three repos -- device_itel_S666LN, -kernel, vendor --
#   on branch lineage-23.2. This file holds only what is the ROM's: ROM identity,
#   signing, app choices, patches to the ROM's own forks. That split matters more on
#   this tree than it did on crDroid: the vendor is a SHARED base for AICP, the
#   OriginOS / One UI ports and AOSPA (decided 2026-11-12), so anything
#   AICP-only that leaks into the device repos travels to systems that are not AICP.
#
# STEP NUMBERS ARE NEVER RENUMBERED. Records refer to steps by number; a
# withdrawn step keeps its number and becomes a documented no-op.
#
set -euo pipefail
TREE="${1:?usage: apply-overlays.sh <path-to-crdroid-tree>}"
cd "$TREE"

echo "===================================================================="
echo " apply-overlays.sh  tree=$TREE"
echo "===================================================================="


# --- step 1: the kernel is the imported Neutron vanilla (v11 since 11-16) ------
# Not an import. On lineage-23.2 the kernel package COMMITS its prebuilt/
# (2026-11-12: a public clone must build, and there is no from-source
# fallback), so the import happens once, in the package, by the device tree's
# import-kernel.sh -- which proves the Image is the one inside the published
# boot image and runs the KMI gate on both module sets. This step re-checks the
# result on every run: the three files are present, still hash to what
# IMPORTED recorded, came from a PUBLISHED image, and are committed.
# BoardConfig.mk $(error)s without them anyway; this says why, earlier.
echo "== step 1: imported kernel present and unchanged =="
KPKG="$TREE/device/itel/S666LN-kernel"
P="$KPKG/prebuilt"
for f in Image.gz vmlinux.symvers kernel.config IMPORTED; do
  [ -s "$P/$f" ] || { echo "   *** FATAL: $P/$f missing -- run device/itel/S666LN/import-kernel.sh vanilla in the kernel package and commit prebuilt/"; exit 1; }
done
( cd "$P" && sed -n 's/^  \([0-9a-f]\{64\}\)  /\1  /p' IMPORTED | sha256sum --quiet -c - ) || {
  echo "   *** FATAL: prebuilt/ no longer matches the sha256 list in IMPORTED"; exit 1; }
grep -q '^published: NONE' "$P/IMPORTED" && {
  echo "   *** FATAL: the imported kernel was never published (ALLOW_UNPUBLISHED=1 import)"; exit 1; }
[ -z "$(git -C "$KPKG" status --porcelain -- prebuilt)" ] || {
  echo "   *** FATAL: prebuilt/ has uncommitted changes in the kernel package"; exit 1; }
sed -n 's/^\(published\|kernel\):  */   \1: /p' "$P/IMPORTED"
echo "   kernel package @ $(git -C "$KPKG" rev-parse --short HEAD) ($(git -C "$KPKG" rev-parse --abbrev-ref HEAD))"


# --- step 2: WITHDRAWN 11-13, a documented no-op ------------------------------
# It hid AOSP's prebuilts/misc/protobuf_vendorcompat (duplicates of
# hardware/lineage/compat's protobuf vendorcompat prebuilts) with a .find-ignore
# marker, after a GENERIC product's analysis died on the duplicate. Our product
# never needed it: vendor/aicp/config/common.mk:6 already sets
#     PRODUCT_SOURCE_ROOT_DIRS += -prebuilts/misc/protobuf_vendorcompat
# for every AICP product (seen in lunch's PRODUCT_SOURCE_ROOT_DIRS). This step
# now only removes a marker an earlier run may have left.
echo "== step 2: (withdrawn) remove the old protobuf .find-ignore marker if present =="
rm -f "$TREE/prebuilts/misc/protobuf_vendorcompat/.find-ignore"


# === FRAMEWORK PATCHES carried from the crDroid recipe (apply-overlays-v2.sh), each
# re-read against A16 on 2026-11-13.
# The crDroid step number is in each title. Obsolete on A16, so NOT here: crDroid 39
# (VkNativeBufferANDROID SPEC 11 carries usage3 + ahb, filled natively), 45/46/48
# (extensions native), 47 (native, conditional), 35/36 (bootctrl and the AIDL power
# impl are gone from 23.2's hardware/mediatek). Every step: guard -> anchor count == 1
# -> post-condition grep, and FATAL on any miss. Paths are listed in tree-edits.txt.
HERE="$(cd "$(dirname "$0")" && pwd)"


# --- step 3: libgui reports BufferQueue frames to ged (GPU DVFS)  [crDroid 41] --
# On MT6789 ged's DVFS loop only runs when told a frame happened; MediaTek's libgui
# does that through libged_kpi.so, AOSP's does not, so the GPU sits at the OPP it
# powered on at (crDroid v3.1: ged_dvfs_run 0 hits in 20 s of gameplay vs 12,152 job
# submits). gedkpi/GedKpiHook.h is crDroid's final header (74e6a1a: queue hands ged
# fence_fd = -1 -- a real fence panicked ged_kpi_gpu_3d_fence_sync_cb and BOOTLOOPED).
# The device tree ships libged_kpi/libged_sys (prebuilts/gedkpi).
# A16 DELTA: queueBuffer's anchor. A13 had `mCore->mDequeueCondition.notify_all();`
# where A16 has `mCore->notifyBufferReleased();`, same position; the hook still sees
# the finished item (already pushed onto mQueue; its GraphicBuffer is cleared only
# further down, as on A13). Dry run on A16 sources: 7 call sites.
echo "== step 3: libgui reports BufferQueue frames to ged (crDroid 41) =="
GUIDIR="$TREE/frameworks/native/libs/gui"
[ -d "$GUIDIR" ] || { echo "   *** FATAL: frameworks/native/libs/gui not found"; exit 1; }
# Header copied UNCONDITIONALLY, before the already-patched test (crDroid lesson: a
# header fix inside the else-branch never reached a build).
cp "$HERE/gedkpi/GedKpiHook.h" "$GUIDIR/GedKpiHook.h"
if grep -q "gedkpi::onQueue" "$GUIDIR/BufferQueueProducer.cpp"; then
  echo "   call sites already patched; GedKpiHook.h refreshed"
else
  python3 - "$GUIDIR" <<'PYGUI'
import sys, os
d = sys.argv[1]
def add_include(fn):
    p = os.path.join(d, fn); s = open(p).read()
    if '"GedKpiHook.h"' in s: return
    i = s.rindex('#include', 0, s.index('namespace android'))
    e = s.index('\n', i) + 1
    open(p, 'w').write(s[:e] + '\n#include "GedKpiHook.h"\n' + s[e:])
def once(s, a, what):
    if s.count(a) != 1: sys.exit("%s anchor count %d, expected 1" % (what, s.count(a)))
for f in ("BufferQueueCore.cpp", "BufferQueueProducer.cpp", "BufferQueueConsumer.cpp"):
    add_include(f)
p = os.path.join(d, "BufferQueueCore.cpp"); s = open(p).read()
a = "        mUnusedSlots.push_front(s);\n    }\n}\n\nBufferQueueCore::~BufferQueueCore() {}"
once(s, a, "BufferQueueCore ctor/dtor")
s = s.replace(a, "        mUnusedSlots.push_front(s);\n    }\n    gedkpi::onCreate(mUniqueId);\n}\n\n"
                 "BufferQueueCore::~BufferQueueCore() {\n    gedkpi::onDestroy(mUniqueId);\n}", 1)
open(p, 'w').write(s)
p = os.path.join(d, "BufferQueueProducer.cpp"); s = open(p).read()
a = "        mCore->mBufferHasBeenQueued = true;\n        mCore->notifyBufferReleased();\n        mCore->mLastQueuedSlot = slot;\n"
once(s, a, "queueBuffer")
s = s.replace(a, a + "\n        // Third argument is QedBuffer_length -- the QUEUE DEPTH, not the slot.\n"
                     "        // item.mGraphicBuffer is cleared further below for non-SF consumers.\n"
                     "        gedkpi::onQueue(mCore->mUniqueId, item.mGraphicBuffer, item.mFence,\n"
                     "                        static_cast<int>(mCore->mQueue.size()));\n", 1)
a = "    if (outBufferAge) {\n        *outBufferAge = mCore->mBufferAge;\n    }\n    addAndGetFrameTimestamps(nullptr, outTimestamps);\n"
once(s, a, "dequeueBuffer")
s = s.replace(a, "    if (outBufferAge) {\n        *outBufferAge = mCore->mBufferAge;\n    }\n"
                 "    gedkpi::onDequeue(mCore->mUniqueId, mSlots[*outSlot].mGraphicBuffer, *outFence);\n"
                 "    addAndGetFrameTimestamps(nullptr, outTimestamps);\n", 1)
a = "            mCore->mConnectedApi = api;\n"
once(s, a, "connect")
s = s.replace(a, a + "            // getCallingPid() directly: mCore->mConnectedPid is not assigned\n"
                     "            // until further below in this function.\n"
                     "            gedkpi::onConnect(mCore->mUniqueId, api,\n"
                     "                              BufferQueueThreadState::getCallingPid());\n", 1)
a = "                    mCore->mConnectedApi = BufferQueueCore::NO_CONNECTED_API;\n"
once(s, a, "disconnect")
s = s.replace(a, a + "                    gedkpi::onDisconnect(mCore->mUniqueId);\n", 1)
open(p, 'w').write(s)
p = os.path.join(d, "BufferQueueConsumer.cpp"); s = open(p).read()
i = s.index("status_t BufferQueueConsumer::acquireBuffer")
j = s.index("\n    return NO_ERROR;\n", i)
s = s[:j] + "\n    gedkpi::onAcquire(mCore->mUniqueId, outBuffer->mGraphicBuffer);\n" + s[j:]
open(p, 'w').write(s)
PYGUI
  [ $? -eq 0 ] || { echo "   *** FATAL: libgui gedkpi patch failed"; exit 1; }
  for c in "onQueue:BufferQueueProducer" "onDequeue:BufferQueueProducer" "onConnect:BufferQueueProducer" \
           "onDisconnect:BufferQueueProducer" "onAcquire:BufferQueueConsumer" "onCreate:BufferQueueCore" \
           "onDestroy:BufferQueueCore"; do
    grep -q "gedkpi::${c%%:*}" "$GUIDIR/${c#*:}.cpp" || { echo "   *** FATAL: gedkpi::${c%%:*} missing"; exit 1; }
  done
  echo "   patched (create/destroy, connect/disconnect, dequeue/queue, acquire)"
fi
# Post-condition on BOTH paths: queue hands ged fence_fd = -1 (the bootloop fix). The
# control is the dequeue call beside it, which legitimately passes a fence.
grep -q 'queueTag(id, -1, queuedBufferCount' "$GUIDIR/GedKpiHook.h" \
  || { echo "   *** FATAL: GedKpiHook.h onQueue is not passing fence_fd = -1 (bootloop fix missing)"; exit 1; }
grep -q 'dequeueTag(id, fd,' "$GUIDIR/GedKpiHook.h" \
  || { echo "   *** FATAL: control failed -- onDequeue not found, the grep above proves nothing"; exit 1; }
echo "   onQueue fence_fd = -1 confirmed (control: onDequeue still passes a fence)"


# --- step 4: AHardwareBuffer_allocate never leaves *outBuffer indeterminate  [crDroid 40]
# A16 still returns early without writing it (AHardwareBuffer.cpp, the gralloc
# failure path), and Mali r54p1 ignores the result of the HAL_PIXEL_FORMAT_R_8 probe
# this gralloc always fails. Defensive -- crDroid's own note: not THE r54p1 crash fix.
echo "== step 4: AHardwareBuffer_allocate clears *outBuffer (crDroid 40) =="
AHB="$TREE/frameworks/native/libs/nativewindow/AHardwareBuffer.cpp"
[ -f "$AHB" ] || { echo "   *** FATAL: $AHB not found"; exit 1; }
if grep -q 'outBuffer indeterminate' "$AHB"; then
  echo "   already patched"
else
  python3 - "$AHB" <<'PYAHB'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    if (!outBuffer || !desc) return BAD_VALUE;\n"
new = old + ("    // Never leave *outBuffer indeterminate. The early returns below do not write\n"
             "    // it, so a caller that ignores the return code keeps whatever its variable\n"
             "    // held -- and AHardwareBuffer_getNativeHandle's null check cannot catch\n"
             "    // garbage, only null. Mali r54p1 ignores the result of its R_8 probe.\n"
             "    *outBuffer = nullptr;\n")
if s.count(old) != 1: sys.exit("anchor count %d, expected 1" % s.count(old))
open(p, "w").write(s.replace(old, new, 1))
PYAHB
  [ $? -eq 0 ] || { echo "   *** FATAL: AHardwareBuffer patch failed"; exit 1; }
  grep -q '\*outBuffer = nullptr;' "$AHB" || { echo "   *** FATAL: clear not present"; exit 1; }
  echo "   patched"
fi


# --- step 5: ART Heap::RecordFree saturates instead of wrapping  [crDroid 37] ----
# A positive freed_bytes larger than num_bytes_allocated_ wraps the counter to ~2^64
# and every later allocation in that process throws OOM (crDroid 2026-08-28: TikTok,
# 5/5 runs, 13 s from launch). RACING_DCHECK_LE is compiled out of user builds;
# RecordFreeRevoke() twenty lines below already guards the same subtraction. A16's
# RecordFree is unchanged upstream; ART builds from source here
# (ReleaseDefaultModuleBuildFromSource = true), so this reaches com.android.art.
echo "== step 5: ART RecordFree underflow clamp (crDroid 37) =="
HEAPCC="$TREE/art/runtime/gc/heap.cc"
[ -f "$HEAPCC" ] || { echo "   *** FATAL: $HEAPCC not found"; exit 1; }
if grep -q 'num_bytes_allocated_ underflow clamped' "$HEAPCC"; then
  echo "   already patched"
else
  python3 - "$HEAPCC" <<'PYART'
import sys
p = sys.argv[1]; s = open(p).read()
old = ("  // Note: This relies on 2s complement for handling negative freed_bytes.\n"
       "  num_bytes_allocated_.fetch_sub(static_cast<ssize_t>(freed_bytes), std::memory_order_relaxed);\n")
new = """  if (LIKELY(freed_bytes > 0)) {
    // Saturate at zero rather than wrapping. RACING_DCHECK_LE above is compiled out of user
    // builds, and a positive freed_bytes CAN exceed the counter (measured: the large object
    // space crediting more freed bytes than were ever added). Unlike the negative case below
    // that wrap is not self-correcting -- num_bytes_allocated_ becomes ~2^64 and every
    // subsequent allocation throws OutOfMemoryError for the life of the process.
    size_t cur = num_bytes_allocated_.load(std::memory_order_relaxed);
    const size_t sub = static_cast<size_t>(freed_bytes);
    size_t next;
    bool clamped;
    do {
      clamped = sub > cur;
      next = clamped ? 0u : cur - sub;
    } while (!num_bytes_allocated_.compare_exchange_weak(cur, next, std::memory_order_relaxed));
    if (UNLIKELY(clamped)) {
      LOG(WARNING) << "num_bytes_allocated_ underflow clamped: freed " << freed_bytes
                   << " bytes against a counter of " << cur;
    }
  } else {
    // Negative freed_bytes is a legitimate increase (padding/binning across space
    // transitions). Keep the original 2s-complement add.
    num_bytes_allocated_.fetch_sub(static_cast<ssize_t>(freed_bytes), std::memory_order_relaxed);
  }
"""
if s.count(old) != 1: sys.exit("anchor count %d, expected 1" % s.count(old))
open(p, "w").write(s.replace(old, new, 1))
PYART
  [ $? -eq 0 ] || { echo "   *** FATAL: ART patch failed"; exit 1; }
  grep -q 'compare_exchange_weak(cur, next' "$HEAPCC" || { echo "   *** FATAL: CAS loop missing"; exit 1; }
  echo "   patched (positive freed_bytes saturates; negative path unchanged)"
fi


# --- step 6: GameManagerService publishes sys.gamemode.active  [crDroid 38] ------
# The device tree's init.cgroup.rc triggers a game-scoped sched_pelt_multiplier on
# property:sys.gamemode.active; nothing else on this device publishes a game signal
# init can see (crDroid getprop diff, 08-28). "sys." is system_prop, settable by
# system_server. A16 DELTA: setPowerMode(Mode.GAME, ...) is called from FIVE places
# (A13: two) -- service start OFF, first non-game OFF, first game ON, no games OFF,
# only games ON -- so the property is set beside every one of them, and exactly five
# is asserted so an upstream change is a FATAL, not a silent partial port.
echo "== step 6: GameManagerService publishes sys.gamemode.active (crDroid 38) =="
GMS="$TREE/frameworks/base/services/core/java/com/android/server/app/GameManagerService.java"
[ -f "$GMS" ] || { echo "   *** FATAL: $GMS not found"; exit 1; }
if grep -q 'sys.gamemode.active' "$GMS"; then
  echo "   already patched"
else
  python3 - "$GMS" <<'PYGMS'
import re, sys
p = sys.argv[1]; s = open(p).read()
pat = re.compile(r'^(\s*)mPowerManagerInternal\.setPowerMode\(Mode\.GAME, (true|false)\);\n', re.M)
n = len(pat.findall(s))
if n != 5: sys.exit("setPowerMode(Mode.GAME, ...) count %d, expected 5" % n)
s = pat.sub(lambda m: m.group(0) + '%sandroid.os.SystemProperties.set("sys.gamemode.active", "%s");\n'
            % (m.group(1), '1' if m.group(2) == 'true' else '0'), s)
open(p, "w").write(s)
PYGMS
  [ $? -eq 0 ] || { echo "   *** FATAL: GameManagerService patch failed"; exit 1; }
  [ "$(grep -c 'sys.gamemode.active' "$GMS")" = "5" ] || { echo "   *** FATAL: expected 5 setters"; exit 1; }
  echo "   patched (5 setters beside setPowerMode(Mode.GAME, ...))"
fi


# --- step 7: bypass charging in Game Space -- NOT patched on crDroid 16 (documented no-op) --
# The tile AICP's step 7 adds came from crDroid's own Android 13 recipe (step 19). crDroid 16's Game Space
# was rewritten (Compose, gamebar/tiles/TileRepository) and has bypass charging BUILT IN: Settings.System
# bypass_charge_enabled, offered when Build.MANUFACTURER is Google (true with the Pixel 10 identity) or
# persist.sys.battery_bypass_supported; frameworks/base GameStateDispatcher holds the charge through
# LineageOS Health charging control (lineageos.health.HealthInterface, MODE_LIMIT at the current level).
# The hook on crDroid 16 is therefore a DEVICE fact -- Lineage Health charging control on the RS4's
# bypass node -- not an app patch. Until the device tree provides it, the toggle has no effect.
echo "== step 7: (crDroid 16) Game Space bypass is native via Lineage Health -- nothing to patch =="

echo "===================================================================="
echo " apply-overlays.sh: all steps OK"
echo "===================================================================="
