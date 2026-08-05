#!/bin/bash
#
# apply-overlays.sh <TREE_PATH>
#
# Idempotent crDroid 13.0 / itel RS4 (S666LN) port fixups. Re-run after any
# `repo sync`. Same discipline as ~/itel_rs4_AOSPA/apply-overlays.sh.
#
# Steps grow as the port progresses. Each step is guarded so re-running is safe.
#
set -euo pipefail
TREE="${1:?usage: apply-overlays.sh <path-to-crdroid-tree>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$TREE"

echo "===================================================================="
echo " apply-overlays.sh  tree=$TREE"
echo "===================================================================="

# --- step 1: Riza custom kernel (vanilla 5.10.260, KMI 0x7c24b32d) ----------
# The A13 device tree's LOCAL_KERNEL := device/itel/S666LN-kernel/Image.gz is a
# prebuilt GKI image. Swap in the Riza vanilla kernel (rootless -> honest e-KYC).
# vendor_dlkm / dtb / dtbo are KMI-matched and unchanged (AnyKernel3 semantics).
echo "== step 1: Riza custom kernel =="
KPKG="$TREE/device/itel/S666LN-kernel"
DT="$TREE/device/itel/S666LN"

# The independently-authored device tree (riza220201/device_itel_S666LN) owns
# kernel import itself and supersedes this step. It does not ship a prebuilt
# Image.gz at the kernel-package root at all -- it builds GKI from source by
# default and uses TARGET_PREBUILT_KERNEL + TARGET_FORCE_PREBUILT_KERNEL when a
# kernel has been imported into S666LN-kernel/prebuilt/. Running the old branch
# against it dies immediately:
#     cp: cannot stat '.../S666LN-kernel/Image.gz': No such file or directory
#
# Delegating is also strictly safer. This step only ever counted 'reflex'
# strings; import-kernel.sh runs the real KMI check -- module_layout plus every
# symbol CRC against all 404 prebuilt vendor modules, both sets -- and REFUSES a
# kernel that would flash cleanly and bootloop.
if [ -x "$DT/import-kernel.sh" ]; then
  echo "   device tree provides import-kernel.sh -- delegating to it"
  ( cd "$DT" && KERNEL_PROJECT="${KERNEL_PROJECT:-$HOME/itel-rs4-kernel}" \
      ./import-kernel.sh "${KERNEL_VARIANT:-vanilla}" ) || {
    echo "   *** FATAL: kernel import/KMI check failed"; exit 1; }
  echo "   staged: $(zcat "$KPKG/prebuilt/Image.gz" | strings | grep -aoE '5\.10\.[0-9]+-Riza-[a-z]+' | head -1)"
  echo "   sha256: $(sha256sum "$KPKG/prebuilt/Image.gz" | cut -c1-16)"
  REFLEX_HITS="$(zcat "$KPKG/prebuilt/Image.gz" | strings | grep -ci reflex || true)"
  [ "$REFLEX_HITS" -ge 5 ] && echo "   reflex governor: PRESENT ($REFLEX_HITS refs)" || {
    echo "   *** FATAL: staged kernel has no reflex governor ($REFLEX_HITS refs)."
    echo "   *** init.mt6789.power.rc selects 'reflex' on policy0/policy6."; exit 1; }
elif [ -f "$HERE/kernel-stage/Image.gz" ]; then
  [ -f "$KPKG/Image.gz.stock" ] || cp "$KPKG/Image.gz" "$KPKG/Image.gz.stock"
  cp "$HERE/kernel-stage/Image.gz" "$KPKG/Image.gz"
  echo "   staged: $(zcat "$KPKG/Image.gz" | grep -aoE '5\.10\.[0-9]+-Riza-[a-z]+' | head -1)"
  echo "   sha256: $(sha256sum "$KPKG/Image.gz" | cut -c1-16)"
  # The uname string is IDENTICAL across kernel revisions (v4 and v5 both report
  # 5.10.260-Riza-vanilla), so it cannot tell them apart. On 2026-07-28 a stale v4
  # copy of kernel-stage/Image.gz on the build VM was staged over the good v5 one
  # and silently shipped a kernel with no reflex governor, while this step still
  # printed a correct-looking version line. Assert on a real feature instead.
  REFLEX_HITS="$(zcat "$KPKG/Image.gz" | strings | grep -ci reflex || true)"
  if [ "$REFLEX_HITS" -ge 5 ]; then
    echo "   reflex governor: PRESENT ($REFLEX_HITS refs)"
  else
    echo "   *** FATAL: staged kernel has no reflex governor ($REFLEX_HITS refs; expected >=5)."
    echo "   *** This is the pre-reflex kernel. The device tree selects 'reflex' for"
    echo "   *** policy0/policy6, so it would silently fall back to schedutil."
    echo "   *** Refresh $HERE/kernel-stage/Image.gz from ~/itel-rs4-kernel/out/vanilla/Image.gz"
    exit 1
  fi
else
  echo "   WARN: $HERE/kernel-stage/Image.gz missing; leaving stock kernel"
fi

# --- step 2: neutralize the device tree's vendorsetup.sh ---------------------
# lineage-20.0 device_itel_S666LN ships a vendorsetup.sh that git-clones the
# device/vendor/kernel/transsion/mediatek/sepolicy_vndr deps itself, and does
# `rm -rf hardware/mediatek` on EVERY `source build/envsetup.sh` (re-clones full
# depth, fights repo). Our local_manifests/S666LN.xml owns all of them as repo
# projects, so make vendorsetup.sh a no-op.
echo "== step 2: neutralize device vendorsetup.sh =="
VS="$TREE/device/itel/S666LN/vendorsetup.sh"
if grep -q "git clone" "$VS" 2>/dev/null; then
  cat > "$VS" <<'EOS'
# Neutralized for the crDroid 13.0 repo-manifest build.
# ~/itel_rs4_Crdroid/local_manifests/S666LN.xml owns device/itel/S666LN{,-kernel},
# vendor/itel/S666LN, hardware/transsion, hardware/mediatek and
# device/mediatek/sepolicy_vndr as repo projects. The upstream lineage-20.0
# vendorsetup.sh git-cloned these (and rm -rf'd hardware/mediatek on every
# source), which fights repo. No-op here.
EOS
  echo "   vendorsetup.sh neutralized"
else
  echo "   vendorsetup.sh already neutralized (no git clone lines)"
fi

# --- step 3: camera RAW/DNG without root (patched MTK cam-HAL libs) ----------
# The RS4 hardware supports RAW, but the STOCK MediaTek HAL blobs don't advertise
# RAW capability to Camera2 (gated off). Swap in the patched libs (from the
# Itel_RS4_RAW_v2 module: a 10-byte capability-gate NOP in customer.so + a
# metastore rebuild) over the stock ones the vendor tree installs to
# /vendor/lib64/mt6789/. Drop-in safe: identical SONAME / DT_NEEDED / exported
# symbols (verified for AOSPA), so no Android.bp change; blob-only -> kati +
# packaging, no soong re-analysis. Aperture already implements DNG capture.
echo "== step 3: camera RAW/DNG blobs =="
CAMDST="$TREE/vendor/itel/S666LN/proprietary/vendor/lib64/mt6789"
if [ -d "$HERE/blobs-camera-raw" ] && [ -d "$CAMDST" ]; then
  for so in libmtkcam_3rdparty.customer.so libmtkcam_metastore.so; do
    if [ -f "$HERE/blobs-camera-raw/$so" ]; then
      [ -f "$CAMDST/$so.stock" ] || cp "$CAMDST/$so" "$CAMDST/$so.stock" 2>/dev/null || true
      cp "$HERE/blobs-camera-raw/$so" "$CAMDST/$so"
      echo "   swapped $so (stock kept as $so.stock)"
    fi
  done
else
  echo "   WARN: blobs-camera-raw or vendor mt6789 dir missing; skipping RAW swap"
fi

# --- step 4: thermal HAL VINTF manifest entry -------------------------------
# /vendor/bin/hw/android.hardware.thermal@2.0-service.mtk ships and starts fine,
# but no VINTF manifest anywhere on the device declares IThermal, so
# hwservicemanager refuses the registration ("must be in VINTF manifest in order
# to register/get") and init respawns the service every ~5s forever. The
# framework side sits at "HAL Ready: false" -> no thermal throttling at all.
# The device tree's generated manifest.xml simply lost the entry; add it back in
# the canonical AOSP form (cf. hardware/google/pixel/thermal/*.pixel.xml), with
# both major versions because the service's own .rc declares both.
echo "== step 4: thermal HAL VINTF entry =="
MANIFEST="$TREE/device/itel/S666LN/configs/vintf/manifest.xml"
if grep -q "android.hardware.thermal" "$MANIFEST"; then
  echo "   thermal already declared"
else
  python3 - "$MANIFEST" <<'EOP'
import sys
path = sys.argv[1]
src = open(path).read()
# Entries are ordered alphabetically; thermal sorts after tetheroffload.control
# and before the vendor.* block.
anchor = '    <hal format="hidl">\n        <name>vendor.dolby.hardware.dms</name>'
block = '''    <hal format="hidl">
        <name>android.hardware.thermal</name>
        <transport>hwbinder</transport>
        <version>1.0</version>
        <version>2.0</version>
        <interface>
            <name>IThermal</name>
            <instance>default</instance>
        </interface>
    </hal>
'''
if anchor not in src:
    raise SystemExit("FATAL: vendor.dolby anchor not found in %s" % path)
open(path, 'w').write(src.replace(anchor, block + anchor, 1))
EOP
  echo "   android.hardware.thermal @1.0+@2.0 IThermal/default declared"
fi

# --- step 5: vndservicemanager (legacy vndbinder context manager) -----------
# AOSP only installs vndservicemanager on devices shipping at API <= 29 (see
# PRODUCT_PACKAGES_SHIPPING_API_LEVEL_29 in build/make/target/product/base_vendor.mk)
# and this device sets PRODUCT_SHIPPING_API_LEVEL := 31, so it was never built in.
# But the vendor blobs come from the A12 MTK BSP and /vendor/bin/pnpmgr still
# opens /dev/vndbinder. With no context manager listening it retried ~1x/s
# forever ("Not able to get context object on /dev/vndbinder" + kernel "binder:
# transaction call to 0:0 failed ... -22") -- the real source of the permanent
# load average of ~12-15. AOSP already ships the matching sepolicy
# (system/sepolicy/{public,vendor}/vndservicemanager.te + file_contexts).
echo "== step 5: vndservicemanager =="
DEVMK="$TREE/device/itel/S666LN/device.mk"
if grep -q "vndservicemanager" "$DEVMK"; then
  echo "   already present"
else
  cat >> "$DEVMK" <<'EOM'

# Legacy vndbinder context manager, for the A12-BSP vendor daemons (pnpmgr).
# Not installed by default because PRODUCT_SHIPPING_API_LEVEL := 31.
PRODUCT_PACKAGES += \
    vndservice \
    vndservicemanager
EOM
  echo "   vndservice + vndservicemanager added to PRODUCT_PACKAGES"
fi

# --- step 6: /data/vendor/audiohal parent dirs ------------------------------
# AudioParamParser wants /data/vendor/audiohal/audio_param/, but its mkdir() is
# not recursive and the parent never existed, so it spun on "utilMkdir(), mkdir
# fail" once a second. sepolicy is already correct on both sides: file_contexts
# labels /data/vendor/audiohal(/.*)? mtk_audiohal_data_file, and
# hal_audio_default already holds create_dir_perms/create_file_perms on it.
# Only the directory was missing.
echo "== step 6: /data/vendor/audiohal dirs =="
INITRC="$TREE/device/itel/S666LN/rootdir/etc/init/hw/init.mt6789.rc"
if grep -q "/data/vendor/audiohal" "$INITRC"; then
  echo "   already present"
else
  python3 - "$INITRC" <<'EOP'
import sys
path = sys.argv[1]
src = open(path).read()
anchor = '    write /proc/bootprof "INIT:post-fs-data"\n'
add = '''
    # AudioParamParser's mkdir() is not recursive, so it can never create
    # audio_param/ while this parent is missing. The audio HAL runs as
    # audioserver; file_contexts labels this tree mtk_audiohal_data_file.
    mkdir /data/vendor/audiohal 0770 audioserver audio
    mkdir /data/vendor/audiohal/audio_param 0770 audioserver audio
'''
if anchor not in src:
    raise SystemExit("FATAL: post-fs-data anchor not found in %s" % path)
open(path, 'w').write(src.replace(anchor, anchor + add, 1))
EOP
  echo "   audiohal data dirs created in post-fs-data"
fi

# --- step 7: sepolicy — a domain for pnpmgr + the captured denials ----------
# Groundwork for the enforcing RC, and already load-bearing: with the device
# booted enforcing, init refuses to start pnpmgr at all —
#   "File /vendor/bin/pnpmgr (labeled vendor_file) has incorrect label or no
#    domain transition from u:r:init:s0 to another SELinux domain defined"
# These stay deliberately minimal; the remaining denials get collected while
# permissive and folded in before the enforcing flip.
echo "== step 7: sepolicy fixups =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"
if [ ! -f "$SEPOL/pnpmgr.te" ]; then
  cat > "$SEPOL/pnpmgr.te" <<'EOT'
# MediaTek's power/performance manager, an A12-BSP vendor blob. It has no domain
# anywhere in device/mediatek/sepolicy_vndr, so under permissive it ran as
# u:r:init:s0 and under enforcing init refuses to start it at all. Give it one.
# It talks to the legacy vndbinder context manager (vndservicemanager, installed
# via device.mk) — without that it retried ~1x/s forever.
type pnpmgr, domain;
type pnpmgr_exec, exec_type, vendor_file_type, file_type;

init_daemon_domain(pnpmgr)
vndbinder_use(pnpmgr)
EOT
  echo "   pnpmgr.te created"
else
  echo "   pnpmgr.te already present"
fi

if ! grep -q "tranlog_device" "$SEPOL/device.te" 2>/dev/null; then
  cat >> "$SEPOL/device.te" <<'EOT'

# Transsion logging control node. It ships unlabeled (u:object_r:device:s0), which
# denied hal_fingerprint_default read access on every FP HAL start.
type tranlog_device, dev_type;
EOT
  echo "   tranlog_device type added"
fi

if ! grep -q "pnpmgr_exec" "$SEPOL/file_contexts" 2>/dev/null; then
  cat >> "$SEPOL/file_contexts" <<'EOT'

/vendor/bin/pnpmgr                                                              u:object_r:pnpmgr_exec:s0
/dev/tranlog_ctl                                                                u:object_r:tranlog_device:s0
EOT
  echo "   pnpmgr + tranlog_ctl labeled"
fi

if ! grep -q "tranlog_device" "$SEPOL/hal_fingerprint_default.te" 2>/dev/null; then
  cat >> "$SEPOL/hal_fingerprint_default.te" <<'EOT'

# The Goodix FP HAL opens /dev/tranlog_ctl on startup (Transsion logging).
allow hal_fingerprint_default tranlog_device:chr_file r_file_perms;
EOT
  echo "   hal_fingerprint_default -> tranlog_device allow added"
fi

# --- step 8: honest stock device identity (RC) ------------------------------
# Present the REAL itel identity, so e-KYC and Play Integrity see a genuine
# device+OS pair (see ~/itel_rs4_AOSPA/EKYC-FACE-VERIFY-FINDING.md). No spoof:
# on A13, "itel S666LN + 13" IS what this hardware actually is.
#
# Target (harvested from stock build 251212V1661, byte-identical to what the
# AOSPA build proved working):
#   Itel/S666LN-OP/itel-S666LN:13/TP1A.220624.014/251212V1661:user/release-keys
#
# HOW the pieces actually land (verified against build/make, 2026-07-28):
#  * generate-common-build-props (core/sysprop.mk:33) runs
#    $(PRODUCT_BUILD_PROP_OVERRIDES) as SHELL assignments, and ONLY THREE props
#    consult them, via ${VAR:-default}: TARGET_PRODUCT, TARGET_DEVICE and
#    PRODUCT_MODEL. The tree's existing "BuildFingerprint=" / "BuildDesc=" lines
#    set shell variables NOTHING reads -- a silent no-op, and pointed at the wrong
#    stock build (240513V1350) besides. They are removed here.
#  * ro.<partition>.build.fingerprint comes from the MAKE var BUILD_FINGERPRINT
#    (sysprop.mk:168 uses it verbatim when already set) -> set in BoardConfig.mk.
#  * plain ro.build.fingerprint is never emitted by buildinfo.sh; init DERIVES it
#    from ro.product.{brand,name,device} + release + BUILD_ID + incremental +
#    type + tags. With all of those made stock-correct the derived value is
#    exactly the target, which is why fixing TARGET_PRODUCT/TARGET_DEVICE matters.
#  * BUILD_ID lives in build/make/core/build_id.mk (repo sync reverts it).
#  * BUILD_NUMBER -> ro.build.version.incremental, exported by the build script.
echo "== step 8: honest stock identity =="
LMK="$TREE/device/itel/S666LN/lineage_S666LN.mk"
BCFG="$TREE/device/itel/S666LN/BoardConfig.mk"
BIDMK="$TREE/build/make/core/build_id.mk"

python3 - "$LMK" <<'EOP'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
if "S666LN-OP" in s and "BuildFingerprint" not in s:
    print("   lineage_S666LN.mk already carries the stock identity"); raise SystemExit
# Drop the no-op override block (BuildDesc/BuildFingerprint shell vars nothing reads).
s = re.sub(r"PRODUCT_BUILD_PROP_OVERRIDES \+=[^\n]*\n(?:[ \t]+\S[^\n]*\\\n)*[ \t]+\S[^\n]*\n", "", s, count=1)
s = s.rstrip("\n") + """

# Honest stock itel identity. Only TARGET_PRODUCT, TARGET_DEVICE and PRODUCT_MODEL
# are actually consumed by generate-common-build-props; they feed ro.product.*,
# which init in turn uses to derive ro.build.fingerprint.
PRODUCT_BUILD_PROP_OVERRIDES += \\
    TARGET_PRODUCT=S666LN-OP \\
    TARGET_DEVICE=itel-S666LN \\
    PRODUCT_MODEL="itel S666LN"
"""
io.open(p, "w", encoding="utf-8").write(s)
print("   lineage_S666LN.mk: no-op overrides removed, stock identity set")
EOP

if ! grep -q "BUILD_FINGERPRINT" "$BCFG"; then
  cat >> "$BCFG" <<'EOM'

# Honest stock fingerprint. sysprop.mk uses this verbatim when already set, so it
# lands in every ro.<partition>.build.fingerprint. Keep the REAL security patch
# (2026-02-01 from the Tier-B merges) -- reporting the older stock 2026-01 to match
# the fingerprint would understate the protection this build actually carries.
BUILD_FINGERPRINT := Itel/S666LN-OP/itel-S666LN:13/TP1A.220624.014/251212V1661:user/release-keys
EOM
  echo "   BoardConfig.mk: BUILD_FINGERPRINT set"
else
  echo "   BoardConfig.mk: BUILD_FINGERPRINT already set"
fi

if ! grep -q "TP1A.220624.014" "$BIDMK"; then
  cp "$BIDMK" "$BIDMK.crdroid.orig" 2>/dev/null || true
  printf 'BUILD_ID=TP1A.220624.014\n' > "$BIDMK"
  echo "   build_id.mk: BUILD_ID -> TP1A.220624.014 (was TQ3A.230901.001)"
else
  echo "   build_id.mk already TP1A.220624.014"
fi

# --- step 9: close the real enforcing denials (RC) --------------------------
# Harvested on-device 2026-07-28 while genuinely ENFORCING (permissive=0, i.e.
# actually blocked), so every rule here answers an observed failure rather than a
# guess. Shell-context denials (adb/dumpsys noise) were excluded.
echo "== step 9: enforcing denials =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"

if ! grep -q "sysfs_pnpmgr" "$SEPOL/file.te" 2>/dev/null; then
  printf '\n# /sys/pnpmgr/* is generic "sysfs", so pnpmgr could not read or write its own\n# tuning nodes (boost_enable, boost_mode, fre_db_cmd, margin_mode, loading_th,\n# fstb_soft_level, fstb_fps_list) once it had a domain of its own.\ntype sysfs_pnpmgr, fs_type, sysfs_type;\n' >> "$SEPOL/file.te"
  echo "   sysfs_pnpmgr type added"
fi
if ! grep -q "sysfs_pnpmgr" "$SEPOL/genfs_contexts" 2>/dev/null; then
  printf '\ngenfscon sysfs /pnpmgr u:object_r:sysfs_pnpmgr:s0\n' >> "$SEPOL/genfs_contexts"
  echo "   /sys/pnpmgr labeled"
fi
if ! grep -q "sysfs_pnpmgr" "$SEPOL/pnpmgr.te" 2>/dev/null; then
  cat >> "$SEPOL/pnpmgr.te" <<'EOT'

# Its own /sys/pnpmgr tuning tree.
allow pnpmgr sysfs_pnpmgr:dir r_dir_perms;
allow pnpmgr sysfs_pnpmgr:file rw_file_perms;

# NOTE: pnpmgr was also seen writing the property_service socket, but the denial
# only names the socket, not which property it wanted — and granting it
# vendor_default_prop is NEVERALLOWED (system/sepolicy/public/domain.te:553:
# "neverallow ... vendor_default_prop:property_service set"), which fails the
# build outright. Left unresolved on purpose: pnpmgr runs fine without it, and
# the right fix needs the property NAME so it can get its own type. Capture it
# from a permissive boot before adding anything here.
EOT
  echo "   pnpmgr sysfs rules added (property set deliberately omitted)"
fi

if ! grep -q "RS4 enforcing fixups" "$SEPOL/dontaudit.te" 2>/dev/null; then
  cat >> "$SEPOL/dontaudit.te" <<'EOT'

# --- RS4 enforcing fixups (denials observed with permissive=0) ---
# hal_power_default asks for dac_override; that is a symptom of file ownership,
# not something to grant -- AOSP neverallows it for good reason. Silence it.
dontaudit hal_power_default self:capability dac_override;
EOT
  echo "   dac_override dontaudit added"
fi

_append_rule() { # file, marker, content
  grep -q "$2" "$SEPOL/$1" 2>/dev/null || { printf '%s\n' "$3" >> "$SEPOL/$1"; echo "   $1: $2"; }
}
# mtk_hal_camera persists per-sensor calibration versions. It cannot be given
# vendor_default_prop (neverallowed, see above), so the properties get their own
# type and a property_contexts prefix match instead.
if ! grep -q "vendor_cam_param_prop" "$SEPOL/property.te" 2>/dev/null; then
  printf '\n# persist.vendor.cam.param.*.version, written by the MTK camera HAL.\nvendor_internal_prop(vendor_cam_param_prop)\n' >> "$SEPOL/property.te"
  echo "   vendor_cam_param_prop type added"
fi
if ! grep -q "vendor_cam_param_prop" "$SEPOL/property_contexts" 2>/dev/null; then
  printf '\npersist.vendor.cam.param.    u:object_r:vendor_cam_param_prop:s0\n' >> "$SEPOL/property_contexts"
  echo "   persist.vendor.cam.param. labeled"
fi
_append_rule mtk_hal_camera.te "vendor_cam_param_prop" "
# Persists per-sensor calibration versions (persist.vendor.cam.param.*.version).
set_prop(mtk_hal_camera, vendor_cam_param_prop)"
_append_rule hal_power_default.te "vendor_mtk_powerhal_prop" "
# Reads its own MTK powerhal tunables.
get_prop(hal_power_default, vendor_mtk_powerhal_prop)"
_append_rule hal_fingerprint_default.te "vendor_data_file:dir" "
# Enumerates /data/vendor/goodix (its own calibration + template store).
allow hal_fingerprint_default vendor_data_file:dir r_dir_perms;"

# --- step 10: release-keys signing (RC) -------------------------------------
# Sign with our own release keys instead of AOSP's public testkey. Without this
# the build is signed by a key whose private half ships in the AOSP source, so
# anything "signature"-protected is effectively world-writable, and the build
# reports test-keys -- which alone fails Play Integrity.
# PRODUCT_DEFAULT_DEV_CERTIFICATE takes a path relative to the tree root and the
# build appends .x509.pem/.pk8, so the keys have to live inside the tree.
# ~/crdroid/vendor/crdroid-keys/ is uploaded out-of-band and never committed
# (the recipe's .gitignore firewalls keys-priv/, *.pk8 and *.x509.pem).
echo "== step 10: release-keys signing =="
KEYDIR="$TREE/vendor/crdroid-keys"
DEVMK="$TREE/device/itel/S666LN/device.mk"
if [ ! -f "$KEYDIR/releasekey.pk8" ]; then
  echo "   *** FATAL: $KEYDIR/releasekey.pk8 missing."
  echo "   *** Upload the key set before building the RC:"
  echo "   ***   scp ~/itel_rs4_Crdroid/keys-priv/*.{pk8,x509.pem} rs4vm:crdroid/vendor/crdroid-keys/"
  exit 1
fi
if ! grep -q "PRODUCT_DEFAULT_DEV_CERTIFICATE" "$DEVMK"; then
  cat >> "$DEVMK" <<'EOM'

# Sign with our own release keys (see vendor/crdroid-keys/). Replaces AOSP's
# testkey, whose private half is public — required for an honest release build.
PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/crdroid-keys/releasekey
EOM
  echo "   PRODUCT_DEFAULT_DEV_CERTIFICATE -> vendor/crdroid-keys/releasekey"
else
  echo "   signing certificate already configured"
fi
echo "   key set: $(ls "$KEYDIR"/*.pk8 2>/dev/null | wc -l) private keys present"

# --- step 11: expose /dev/ntsync to apps (Winlator / Wine) ------------------
# The Riza kernel builds CONFIG_NTSYNC=y, but the kernel is only half of it: the
# node ships as `crw------- root root u:object_r:device:s0`, i.e. unlabeled AND
# mode 0600, so an app cannot open it no matter what SELinux says. Both halves
# are fixed here — ueventd for the DAC bits, sepolicy for the MAC bits.
# Without this, ntsync is dead weight and Wine silently falls back to esync/fsync.
echo "== step 11: /dev/ntsync for apps =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"
UEVENTD="$TREE/device/itel/S666LN/rootdir/etc/ueventd.mt6789.rc"

if ! grep -q "ntsync" "$UEVENTD" 2>/dev/null; then
  printf '\n# NT synchronization primitives, used by Wine/Winlator. Ships 0600 root:root,\n# which blocks apps before SELinux even gets a say.\n/dev/ntsync               0666   root       root\n' >> "$UEVENTD"
  echo "   ueventd: /dev/ntsync 0666"
else
  echo "   ueventd already has ntsync"
fi

if ! grep -q "ntsync_device" "$SEPOL/device.te" 2>/dev/null; then
  printf '\n# /dev/ntsync (CONFIG_NTSYNC). Its own type so apps can be granted access\n# without widening anything else — the app neverallows are per-type.\ntype ntsync_device, dev_type;\n' >> "$SEPOL/device.te"
  echo "   ntsync_device type added"
fi
if ! grep -q "ntsync" "$SEPOL/file_contexts" 2>/dev/null; then
  printf '/dev/ntsync                                                                     u:object_r:ntsync_device:s0\n' >> "$SEPOL/file_contexts"
  echo "   /dev/ntsync labeled"
fi
if [ ! -f "$SEPOL/ntsync_app.te" ]; then
  cat > "$SEPOL/ntsync_app.te" <<'EOT'
# Let ordinary apps use /dev/ntsync. This is the whole point of shipping the
# driver: Wine (Winlator/Proton) backs Windows semaphores, mutexes and events
# with real kernel objects instead of eventfd-based esync/fsync.
#
# Deliberately scoped to its own type. AOSP's app neverallows name specific
# device types (graphics_device, nfc_device, tee_device, vndbinder_device,
# kmsg_device...), not dev_type as a whole, so a purpose-made ntsync_device is
# permitted where a generic grant would not be.
# A13 defines exactly these four legacy targetSdk variants alongside
# untrusted_app -- there is no untrusted_app_32. Enumerated rather than using a
# broad attribute so isolated_app (WebView renderers and friends) is NOT granted
# access; nothing sandboxed has any business opening a sync primitive device.
allow untrusted_app ntsync_device:chr_file rw_file_perms;
allow untrusted_app_25 ntsync_device:chr_file rw_file_perms;
allow untrusted_app_27 ntsync_device:chr_file rw_file_perms;
allow untrusted_app_29 ntsync_device:chr_file rw_file_perms;
allow untrusted_app_30 ntsync_device:chr_file rw_file_perms;
EOT
  echo "   ntsync_app.te created (untrusted_app + API-level variants)"
fi

# --- step 12: Google apps baked in (MindTheGapps, branch "tau" = Android 13) -
# crDroid's own GApps hook is vendor/lineage/config/partner_gms.mk, which wants
# Google's `vendor/partner_gms` partner package -- not publicly distributable and
# not in this tree. MindTheGapps is the A13 equivalent everyone else uses, and it
# is a real build-time vendor tree rather than a flashable installer.
#
# WHY BAKED IN RATHER THAN FLASHED: a post-hoc GApps installer has to drop
# privileged APKs into /product/priv-app AND register their privapp-permissions
# whitelist, default-permissions, sysconfig and SELinux labels after the images
# are already sealed. On a `user` build running ENFORCING that routinely leaves
# GMS half-provisioned, and the visible symptom is exactly the one seen with
# NikGapps on 2026-07-28: Play Store cannot update Play Services. Inheriting the
# vendor tree instead puts all of that in the image at build time
# (common-vendor.mk copies privapp-permissions-google-product.xml,
# default-permissions-google.xml, sysconfig/google.xml, the hiddenapi allowlist
# and the fsverity cert), so the normal update path works.
#
# Branch naming: MindTheGapps uses Greek letters, NOT version numbers.
#   pi=9  qoppa=10  rho=11  sigma=12  *tau=13*  upsilon=14  vic=15
# `tau` is frozen (last commit 2023-11-12) because A13 GApps stopped moving; the
# bundled APKs self-update from the Play Store, so this is not a staleness issue.
echo "== step 12: GApps (MindTheGapps tau) =="
GAPPS="$TREE/vendor/gapps"
DEVMK="$TREE/device/itel/S666LN/device.mk"

# VANILLA=1 builds a GApps-FREE ROM so a GApps package can be flashed on top.
# Used to test whether GApps provisioning (in particular Google's SetupWizard,
# which step 16 drops) is what costs this device MEETS_STRONG_INTEGRITY -- every
# other candidate has been eliminated with evidence: identity, both SPLs, fenrir,
# AVB, signing keys, kernel, root, GMS version (sideload test) and /data-wipe
# device reputation (retested after a day of normal use, still DEVICE).
# NOTE the known trade-off: a flashed installer cannot register privapp-permissions,
# default-permissions, sysconfig and SELinux labels after the images are sealed, which
# on a `user` build running enforcing is exactly why NikGapps left Play Store unable
# to update Play Services. That is what baking GApps in was solving.
if [ "${VANILLA:-0}" = "1" ]; then
  if grep -q "vendor/gapps/arm64/arm64-vendor.mk" "$DEVMK"; then
    python3 - "$DEVMK" <<'EOP'
import sys, re
path = sys.argv[1]
src = open(path).read()
# drop the inherit line plus the comment block the non-vanilla path appends
pat = re.compile(r"\n# Google apps \(MindTheGapps.*?arm64-vendor\.mk\)\n", re.S)
new, n = pat.subn("\n", src)
if n == 0:
    new = "\n".join(l for l in src.splitlines(True)
                    if "vendor/gapps/arm64/arm64-vendor.mk" not in l)
open(path, "w").write(new)
EOP
    echo "   VANILLA: removed the GApps inherit from device.mk"
  else
    echo "   VANILLA: device.mk already GApps-free"
  fi
  # vendor/gapps is left on disk but unreferenced; inherit-product-if-exists is
  # gone, so nothing in it is built.
  echo "   VANILLA: building WITHOUT GApps (flash a GApps package after)"
else

if [ ! -f "$GAPPS/arm64/arm64-vendor.mk" ]; then
  echo "   vendor/gapps missing -> cloning MindTheGapps (branch tau)"
  rm -rf "$GAPPS.tmp"
  git clone --quiet --depth 1 -b tau https://gitlab.com/MindTheGapps/vendor_gapps.git "$GAPPS.tmp"
  rm -rf "$GAPPS"
  mv "$GAPPS.tmp" "$GAPPS"
fi

# Prune every architecture we do not build. This is NOT just disk hygiene: each
# arch dir defines Soong modules under the SAME names (GmsCore, Phonesky, ...),
# and the build scans the whole tree, so leaving them in place fails the build on
# duplicate module definitions. Keeps ~930M of arm64 out of ~2.9G.
for d in arm x86 x86_64 toybox-arm toybox-x86 toybox-x86_64 cicd .git; do
  rm -rf "${GAPPS:?}/$d"
done

if ! grep -q "vendor/gapps/arm64/arm64-vendor.mk" "$DEVMK"; then
  cat >> "$DEVMK" <<'EOM'

# Google apps (MindTheGapps, branch "tau" = Android 13), baked into the build so
# nothing has to be sideloaded afterwards. arm64-vendor.mk pulls in
# common-vendor.mk itself, which carries the privapp-permissions and sysconfig
# XML that a flashed installer cannot register properly on an enforcing build.
# -if-exists so a tree without vendor/gapps still builds as a vanilla ROM.
$(call inherit-product-if-exists, vendor/gapps/arm64/arm64-vendor.mk)
EOM
  echo "   device.mk: inherits vendor/gapps/arm64/arm64-vendor.mk"
else
  echo "   device.mk already inherits the GApps vendor makefile"
fi
if [ -f "$GAPPS/arm64/arm64-vendor.mk" ]; then
  echo "   vendor/gapps staged: $(du -sh "$GAPPS" | cut -f1) (arm64 + common)"
fi
# NOTE on setup wizards: MindTheGapps installs Google's SetupWizard to
# system_ext/priv-app/SetupWizard, while crDroid adds LineageSetupWizard
# unconditionally (vendor/lineage/config/common.mk:125, NOT gated on GMS). Both
# ship, and that is correct: LineageSetupWizard is GMS-aware --
# SetupWizardActivity:46 calls SetupWizardUtils.hasGMS() and stands down when
# com.google.android.gms and com.google.android.setupwizard are both installed.
# Do NOT "fix" this by adding LineageSetupWizard to the Google module's
# `overrides:`; coexistence is the designed path.
fi

# --- step 13: stop forcing ADB on (RC) --------------------------------------
# The device tree shipped a debug block that hard-set, via
# PRODUCT_DEFAULT_PROPERTY_OVERRIDES: ro.secure=0, ro.adb.secure=0,
# ro.debuggable=1 and persist.sys.usb.config=adb. Effect on the RC: USB debugging
# was ON out of the box without developer options ever being enabled.
#
# The ro.* three were inert in practice -- they land in vendor/build.prop, and
# system/build.prop is loaded first, so the correct user-build values (ro.secure=1,
# ro.debuggable=0, ro.adb.secure=1) won; the device confirms those at runtime.
# persist.sys.usb.config is NOT a ro. prop, so it applied. On top of that,
# build/make/tools/post_process_props.py appends ",adb" to persist.sys.usb.config
# whenever ro.debuggable=1, and UsbDeviceManager turns that into
# Settings.Global.adb_enabled=1 on first boot. Hence: debugging on by default.
#
# Removing the block outright is the whole fix, and it is variant-correct: a
# userdebug build still gets ro.debuggable=1 from the variant itself (main.mk),
# so post_process_props re-adds adb there automatically, while a `user` RC ships
# with USB debugging off, as it should.
echo "== step 13: drop the forced-ADB debug block =="
python3 - "$DEVMK" <<'EOP'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
# Guard on a real make assignment (indented continuation line), NOT a bare substring: the
# replacement comment written below mentions persist.sys.usb.config=adb by name, so a substring
# test matches its own output and makes this step fail on the second run.
if not re.search(r"(?m)^[ \t]+persist\.sys\.usb\.config=adb[ \t]*$", s):
    print("   device.mk: forced-ADB block already removed"); raise SystemExit
pat = re.compile(
    r"(?m)^[ \t]*#[^\n]*ADB[^\n]*\n"
    r"^PRODUCT_DEFAULT_PROPERTY_OVERRIDES \+= \\\n"
    r"(?:^[ \t]+\S[^\n]*\\\n)*"
    r"^[ \t]+persist\.sys\.usb\.config=adb[ \t]*\n")
s2, n = pat.subn(
    "# USB debugging is deliberately NOT forced on here. The stock device tree set\n"
    "# ro.secure=0 / ro.adb.secure=0 / ro.debuggable=1 / persist.sys.usb.config=adb,\n"
    "# which left adb enabled on a user build before developer options were ever\n"
    "# touched. The build variant already supplies the right values for each flavor.\n",
    s, count=1)
if n != 1:
    raise SystemExit("   *** FATAL: forced-ADB block present but did not match the "
                     "expected shape -- edit device.mk by hand and re-check")
io.open(p, "w", encoding="utf-8").write(s2)
print("   device.mk: forced-ADB block removed (ro.secure/ro.adb.secure/ro.debuggable/usb.config)")
EOP

# --- step 14: restore a signable, stock-shaped ro.build.description ---------
# BLOCKER this fixes: `sign_target_files_apks` aborts with a bare AssertionError at
# RewriteProps (sign_target_files_apks.py:887):
#     elif key == "ro.build.description":
#       pieces = value.split(" ")
#       assert pieces[-1].endswith("-keys")
# crDroid's commit 29535c284 "Make build ID simple" rewrote sysprop.mk:206 from AOSP's
#     BUILD_DESC := $(TARGET_PRODUCT)-$(TARGET_BUILD_VARIANT) $(PLATFORM_VERSION) \
#                   $(BUILD_ID) $(BUILD_NUMBER_FROM_FILE) $(BUILD_VERSION_TAGS)
# down to just $(BUILD_ID), so the build emits a ONE-token `ro.build.description=TP1A.220624.014`
# with no "-keys" suffix. Cosmetic for crDroid (it only wanted a tidy About-phone string), fatal
# for the release flow: the whole tree is unsignable by stock releasetools until this is restored.
#
# We restore it to the EXACT stock string rather than AOSP's formula. The formula would expand to
# "lineage_S666LN-user 13 ...", leaking the ROM's internal product name into a prop that is part of
# the identity set, whereas the harvested stock value is what this hardware really reports.
# Same reasoning as BUILD_FINGERPRINT in step 8, and it keeps ro.build.flavor/description consistent
# with the fingerprint (EKYC-FACE-VERIFY-FINDING.md).
# Both vars are confined to sysprop.mk + tools/buildinfo.sh (pure prop generation) -- AOSP's own
# comment at sysprop.mk:224 notes ro.build.flavor is "used only by the test harness".
# BUILD_DESC also feeds BUILD_DISPLAY_ID, but only on the NON-user branch (sysprop.mk:221), so the
# user RC's About-phone string is unchanged.
echo "== step 14: signable stock ro.build.description =="
SYSPROP="$TREE/build/make/core/sysprop.mk"
BCFG="$TREE/device/itel/S666LN/BoardConfig.mk"

python3 - "$SYSPROP" <<'EOP'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
n = 0
# Make both overridable from BoardConfig.mk instead of hardcoded here.
s, k = re.subn(r"(?m)^BUILD_DESC := \$\(BUILD_ID\)$",
               "BUILD_DESC ?= $(BUILD_ID)", s); n += k
s, k = re.subn(r"(?m)^TARGET_BUILD_FLAVOR := \$\(TARGET_PRODUCT\)-\$\(TARGET_BUILD_VARIANT\)$",
               "TARGET_BUILD_FLAVOR ?= $(TARGET_PRODUCT)-$(TARGET_BUILD_VARIANT)", s); n += k
if n:
    io.open(p, "w", encoding="utf-8").write(s)
    print("   sysprop.mk: %d assignment(s) made overridable (:= -> ?=)" % n)
else:
    print("   sysprop.mk already overridable")
EOP

if ! grep -q "^BUILD_DESC" "$BCFG"; then
  cat >> "$BCFG" <<'EOM'

# Stock ro.build.description / ro.build.flavor, harvested from build 251212V1661.
# REQUIRED for release signing: sign_target_files_apks asserts that the last token of
# ro.build.description ends in "-keys", and crDroid reduces the whole string to $(BUILD_ID).
# Values are the real ones this hardware reports, matching BUILD_FINGERPRINT above.
BUILD_DESC := sys_tssi_64_armv82_itel-user 13 TP1A.220624.014 974711 release-keys
TARGET_BUILD_FLAVOR := sys_tssi_64_armv82_itel-user
EOM
  echo "   BoardConfig.mk: stock BUILD_DESC + TARGET_BUILD_FLAVOR set"
else
  echo "   BoardConfig.mk already carries BUILD_DESC"
fi

# --- step 15: HONEST IDENTITY — disable crDroid's Pixel spoofing ------------
# THE integrity blocker, found 2026-07-28 from a Play Integrity dialog reporting
#   Labels: []   Build fingerprint: google/barbet/barbet:14/AP2A.240805.005/...  Model: Pixel 5a
# on a device whose build.prop honestly says Itel/S666LN-OP/itel-S666LN:13/...
#
# crDroid ships frameworks/base/core/java/com/android/internal/util/crdroid/PixelPropsUtils.java,
# which does TWO things, both wrong for this project:
#
#  1. Rewrites Build.* for Google apps. GMS ("unstable" process) is spoofed to a Pixel 9 on
#     ANDROID 15 (google/tokay_beta/tokay:15/BP11.241025.006, SPL 2024-11-05); Play Store
#     (com.android.vending) and a catch-all `else` branch get Pixel 5a on ANDROID 14. Our system is
#     Android 13. Advertising an A14/A15 fingerprint from an A13 system is an impossible
#     combination that Google's servers reject outright.
#  2. onEngineGetCertificateChain() (called from keystore/.../AndroidKeyStoreSpi.java:169) THROWS
#     UnsupportedOperationException whenever DroidGuard or Finsky asks for the key attestation
#     chain -- "Blocked key attestation". That is why the verdict list came back EMPTY rather than
#     merely lacking STRONG: Play Integrity could not obtain an attestation at all.
#
# Blocking attestation is a sensible default for devices with a revoked/absent keybox. THIS device
# has a genuine Trustonic keybox, and per ~/itel_rs4_AOSPA/EKYC-FACE-VERIFY-FINDING.md:210 its
# STRONG verdict came from that hardware keybox + green verified boot and survived changing the
# fingerprint entirely. crDroid's spoof therefore sabotages a device that passes honestly, and it
# contradicts this project's founding rule: on A13, "itel S666LN + 13" IS a real device+OS pair.
#
# HOW: SPOOF_PIXEL_PI ("persist.sys.pixelprops.pi", default TRUE) already gates spoofBuildGms() and
# onEngineGetCertificateChain(), but NOT the per-package Build rewriting in setProps() (vending at
# :305, gms at :308, and the catch-all `else` at :331 are unconditional). We add the same gate at
# the top of setProps(), making that one property a true master switch, then set it false.
echo "== step 15: honest identity (disable Pixel spoofing) =="
PPU="$TREE/frameworks/base/core/java/com/android/internal/util/crdroid/PixelPropsUtils.java"

if [ -f "$PPU" ]; then
  python3 - "$PPU" <<'EOP'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()

# 1. A compile-time constant kill switch. Deliberately NOT a system property: the toggles are being
#    removed from Settings (step 17), so there must be no way to turn spoofing back on. A plain
#    `return;` as the first statement would be an "unreachable statement" compile error, whereas the
#    JLS explicitly exempts `if`, so `if (!SPOOF_ENABLED) return;` is the correct idiom here.
if "SPOOF_ENABLED" not in s:
    s, n = re.subn(r"(?m)^(    private static final boolean DEBUG = false;\n)",
        r"\1"
        "\n"
        "    // RS4: Pixel spoofing is disabled outright. This ROM presents the device's REAL itel\n"
        "    // identity -- on A13 \"itel S666LN + 13\" is a genuine device+OS pair, and the RS4 has a\n"
        "    // real Trustonic keybox, so it reports MEETS_STRONG_INTEGRITY honestly. crDroid's spoof\n"
        "    // BROKE that: it advertised an Android 14/15 Pixel fingerprint from an A13 system (an\n"
        "    // impossible pair) and, worse, onEngineGetCertificateChain() threw on every DroidGuard\n"
        "    // attestation request, so Play Integrity returned an EMPTY verdict list.\n"
        "    private static final boolean SPOOF_ENABLED = false;\n", s, count=1)
    if n != 1:
        raise SystemExit("   *** FATAL: could not anchor SPOOF_ENABLED on the DEBUG constant")

# 2. Retire every existing SPOOF_PIXEL_PI gate (spoofBuildGms, onEngineGetCertificateChain, and the
#    setProps guard if a previous run added one) onto the constant. Handles both the one-line and
#    wrapped forms crDroid uses.
s, a = re.subn(r"if \(!SystemProperties\.getBoolean\(SPOOF_PIXEL_PI, true\)\)\s*\n\s*return;",
               "if (!SPOOF_ENABLED)\n            return;", s)
s, b = re.subn(r"if \(!SystemProperties\.getBoolean\(SPOOF_PIXEL_PI, true\)\) return;",
               "if (!SPOOF_ENABLED) return;", s)

# 3. Guard setProps() itself -- the per-package rewriting (vending :305, gms :308, catch-all else
#    :331) was never covered by SPOOF_PIXEL_PI at all.
if "if (!SPOOF_ENABLED) return;\n        propsToChangeGeneric" not in s:
    s, n = re.subn(r"(public static void setProps\(Context context\) \{\n)",
                   r"\1        if (!SPOOF_ENABLED) return;\n", s, count=1)
    if n != 1:
        raise SystemExit("   *** FATAL: could not find setProps(Context) to gate")

io.open(p, "w", encoding="utf-8").write(s)
print("   PixelPropsUtils: SPOOF_ENABLED=false; %d gate(s) retired onto it" % (a + b))
EOP
else
  echo "   WARN: $PPU not found — crDroid may have renamed it; re-check the spoofing path"
fi

# Turn the master switch off. persist.* values in build.prop act as the boot default (nothing has
# ever written this key to /data/property), so this is what init applies.
LMK="$TREE/device/itel/S666LN/lineage_S666LN.mk"
if ! grep -q "pixelprops.pi" "$LMK"; then
  cat >> "$LMK" <<'EOM'

# No Pixel spoofing. This ROM presents the device's real itel identity to Google apps, and lets
# the genuine hardware keybox answer Play Integrity's attestation instead of blocking it.
# CONFIRMED ON DEVICE 2026-07-28: with these off the RS4 reports MEETS_STRONG_INTEGRITY, because
# ro.boot.verifiedbootstate=green + flash.locked=1 + veritymode=enforcing + a real Trustonic keybox
# + a genuinely Play-certified itel fingerprint is all Play Integrity ever needed. The spoof was
# the only thing standing in the way.
# `.pi` is the master switch (step 15 gates setProps() on it, so all per-package spoofing stops
# too); the rest are set explicitly so the toggles in crDroid Settings -> Misc read consistently
# and nothing silently resumes spoofing if `.pi` is ever turned back on. `.gphotos` in particular
# defaults to TRUE upstream and claims a Pixel identity to obtain free Photos storage.
PRODUCT_SYSTEM_PROPERTIES += \
    persist.sys.pixelprops.pi=false \
    persist.sys.pixelprops.games=false \
    persist.sys.pixelprops.gphotos=false \
    persist.sys.pixelprops.netflix=false
EOM
  echo "   lineage_S666LN.mk: persist.sys.pixelprops.pi=false"
else
  echo "   pixelprops.pi already set"
fi

# --- step 16: drop Google's SetupWizard (operator decision) ------------------
# MindTheGapps installs com.google.android.setupwizard to system_ext/priv-app. On this build it
# crashed repeatedly during first-run setup --
#   FATAL EXCEPTION: main / java.lang.IllegalThreadStateException at java.lang.Thread.start
#   at bug.f(PG:2)   (obfuscated Google code -- not patchable by us)
# surfacing as "Penyiapan Android terus berhenti", and its Wi-Fi page could not connect. Both
# symptoms live inside that one APK; its permissions were all granted (NETWORK_SETUP_WIZARD,
# CHANGE_WIFI_STATE, ACCESS_WIFI_STATE all granted=true), so this is an internal bug in the
# 2023-vintage build, not an integration gap.
# Removing it hands setup back to LineageSetupWizard, which is already installed and whose Wi-Fi
# page is the ROM's own well-tested one. SetupWizardUtils.hasGMS() then returns false (it requires
# com.google.android.setupwizard to be present), so Lineage's wizard runs the full flow instead of
# standing down. GApps are unaffected: Play Store/GMS do not need Google's wizard, only the Google
# account restore flow is lost, which is reachable later from Settings.
echo "== step 16: drop Google's SetupWizard =="
GVMK="$TREE/vendor/gapps/arm64/arm64-vendor.mk"
if [ "${VANILLA:-0}" = "1" ]; then
  echo "   VANILLA: no GApps in the image, so there is no Google SetupWizard to drop."
  echo "   VANILLA: whichever wizard ships comes from the GApps package you flash."
elif [ -f "$GVMK" ]; then
  if grep -qE "^[[:space:]]+SetupWizard$" "$GVMK"; then
    python3 - "$GVMK" <<'EOP'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
# It is the last entry of its PRODUCT_PACKAGES block, so the preceding line's trailing "\" goes too.
s2, n = re.subn(r"[ \t]*\\\n[ \t]+SetupWizard\n", "\n", s, count=1)
if n != 1:
    s2, n = re.subn(r"(?m)^[ \t]+SetupWizard\n", "", s, count=1)
if n != 1:
    raise SystemExit("   *** FATAL: SetupWizard present but not in the expected shape")
io.open(p, "w", encoding="utf-8").write(s2)
print("   arm64-vendor.mk: Google SetupWizard removed from PRODUCT_PACKAGES")
EOP
  else
    echo "   Google SetupWizard already removed"
  fi
else
  echo "   WARN: $GVMK missing — run step 12 first"
fi

# --- step 17: remove the spoof toggles from crDroid Settings -> Misc --------
# Step 15 makes PixelPropsUtils inert at compile time, so these switches would be dead controls.
# Worse, "Google Play Integrity" reads as something that HELPS integrity while on this device it can
# only destroy it (it re-blocks hardware attestation and re-asserts an impossible A14/A15 identity),
# and it defaults to ON upstream. Operator decision 2026-07-28: remove all four.
#   * Google Play Integrity -- a footgun here, nothing to gain, STRONG to lose.
#   * Game FPS spoof        -- was useful years ago; today ~90% of online games ban for it.
#   * Limitless photo storage -- claims a Pixel identity to obtain a paid perk; also, keeping it
#     alone would mean restructuring setProps() rather than guarding it, since the photos branch
#     (:303) sits inside the same if/else chain as vending and gms.
#   * Netflix               -- not wanted.
# Miscellaneous.java only ever calls SystemProperties.set() on these keys (its reset() path), never
# findPreference(), so removing the XML entries needs no Java change.
echo "== step 17: remove spoof toggles from Settings =="
MISCXML="$TREE/packages/apps/crDroidSettings/res/xml/crdroid_settings_misc.xml"
if [ -f "$MISCXML" ]; then
  python3 - "$MISCXML" <<'EOP'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
removed = []
for key in ("pi", "games", "gphotos", "netflix"):
    # The element has no '>' until its self-closing '/>', so a negated class spans its lines safely.
    pat = re.compile(
        r"(?:[ \t]*<!--[^\n]*-->\n)?"
        r"[ \t]*<com\.crdroid\.settings\.preferences\.SystemPropertySwitchPreference"
        r"[^>]*?android:key=\"persist\.sys\.pixelprops\." + key + r"\"[^>]*?/>\n\n?")
    s, n = pat.subn("", s, count=1)
    if n:
        removed.append(key)
if removed:
    io.open(p, "w", encoding="utf-8").write(s)
    print("   removed toggles: " + ", ".join(removed))
else:
    print("   spoof toggles already removed")
left = re.findall(r"persist\.sys\.pixelprops\.\w+", s)
print("   remaining pixelprops references in misc xml: %d" % len(left))
EOP
else
  echo "   WARN: $MISCXML not found — crDroidSettings may have moved"
fi

# --- step 18: finish the stock identity (the last two leaks) ----------------
# Found 2026-07-28 by a per-partition build.prop audit on the running device. Step 8 made the
# fingerprint and ro.product.* stock everywhere EXCEPT the system partition, which still announced
# itself as LineageOS:
#
#   partition                                  .name             .device
#   product/vendor/odm/system_ext/*_dlkm       S666LN-OP         itel-S666LN
#   system                                     lineage_S666LN    S666LN        <-- leak
#
# `getprop ro.product.name` resolves to S666LN-OP regardless (system is LAST in the property source
# order), which is why this was previously dismissed as harmless -- but that reasoning only covers
# runtime property lookup. Anything reading the system partition's own build.prop still sees
# `lineage_S666LN`. AOSPA sets these explicitly (aospa_S666LN.mk:60-61) and crDroid never did; this
# was the only configuration difference left between the two ROMs' reported identity.
#
# NOTE: this did NOT restore MEETS_STRONG_INTEGRITY when tested live via resetprop (still DEVICE).
# It is kept because a ROM claiming an honest stock identity should not have one partition saying
# otherwise -- correctness, not integrity theatre.
#
# VENDOR_SECURITY_PATCH: the device tree hardcodes 2025-03-05, but the stock vendor blobs we
# actually ship report 2025-04-05 (stock-props/vendor.build.prop). We were UNDERSTATING our own
# vendor patch level. Corrected to the true value.
# Deliberately NOT set to 2026-02-01 (the system SPL) even though a reference write-up for a similar
# Infinix port did exactly that: the vendor partition really is stock A12 blobs, and claiming a
# Feb-2026 vendor patch would be a plain lie. Tested live anyway -- it did not restore STRONG either.
echo "== step 18: finish the stock identity =="
LMK="$TREE/device/itel/S666LN/lineage_S666LN.mk"
BCFG="$TREE/device/itel/S666LN/BoardConfig.mk"

if ! grep -q "PRODUCT_SYSTEM_NAME" "$LMK"; then
  cat >> "$LMK" <<'EOM'

# The system partition's own identity. Without these it reports PRODUCT_NAME (lineage_S666LN),
# leaving one partition announcing LineageOS while every other one reports the stock itel identity.
# Mirrors AOSPA (aospa_S666LN.mk:60-61).
PRODUCT_SYSTEM_NAME := S666LN-OP
PRODUCT_SYSTEM_DEVICE := S666LN
EOM
  echo "   lineage_S666LN.mk: PRODUCT_SYSTEM_NAME/DEVICE -> stock"
else
  echo "   PRODUCT_SYSTEM_NAME already set"
fi

if grep -q "^VENDOR_SECURITY_PATCH := 2025-03-05" "$BCFG"; then
  sed -i 's/^VENDOR_SECURITY_PATCH := 2025-03-05/VENDOR_SECURITY_PATCH := 2025-04-05/' "$BCFG"
  echo "   BoardConfig.mk: VENDOR_SECURITY_PATCH 2025-03-05 -> 2025-04-05 (true stock value)"
else
  echo "   VENDOR_SECURITY_PATCH already corrected ($(grep -m1 '^VENDOR_SECURITY_PATCH' "$BCFG" | cut -d' ' -f3))"
fi

# --- step 19: bypass-charging tile in GameSpace -----------------------------
# Let the adapter carry the system load instead of charging the cell, so a long
# session on the charger does not cook the battery. Proven on this hardware at
# 18% on USB: current_now +400 mA -> ~0 mA on enable, +423 mA on release. Near
# zero rather than strongly negative is what makes it a true BYPASS rather than
# merely "charging stopped" (power_path_support is declared in the DT and
# /proc/mtk_battery_cmd/en_power_path=1).
#
# UX: game-bar tile, NOT a QS tile -- people want this for gaming specifically,
# and crDroid ships GameSpace natively, which is why this ROM was the cheap
# place to put it.
#
# WIRING, and why it is shaped this way:
#  * The node /sys/devices/platform/charger/tran_aichg_disable_charger is mode
#    0666 but labeled sysfs_aichg_file with NO allow rule anywhere, so SELinux
#    is the only real gate. The earlier manual write only worked because it was
#    done as root.
#  * GameSpace is platform-signed with sharedUserId=android.uid.system, so it
#    runs as system_app (seapp_contexts:146), NOT priv_app -- which matters,
#    because priv_app.te:230 neverallows priv_app setting ANY property.
#  * The app writes the node DIRECTLY. The original plan routed through a
#    property + an init "on property:" trigger (mirroring the tree's own "MTK
#    fast charging support" block, which writes a sibling node in the same
#    directory). That is not implementable from a coredomain writer:
#    system/sepolicy/private/property.te:324 neverallows every coredomain except
#    init from setting a vendor property, and no choice of vendor property macro
#    escapes it -- vendor_public_prop clears the READ neverallow that
#    vendor_internal_prop imposes, but the set is still refused. Verified by
#    building precompiled_sepolicy, which failed with
#      "allow system_app_33_0 vendor_charge_bypass_prop (property_service (set))".
#    Note the same failure proves vendor policy CAN grant to coredomain: the
#    rule compiled and was versioned to system_app_33_0, it only tripped a
#    neverallow. So the single file allow below is structurally fine.
#  * Nothing persists the setting. The node resets to 0 on reboot, so a crash
#    that skipped the session-end restore can never leave a phone that silently
#    refuses to charge. The preference persists in AppSettings and is re-applied
#    at session start -- the same split stayAwake already uses.
echo "== step 19: GameSpace bypass-charging tile =="
GS="$TREE/packages/apps/GameSpace/app/src/main"
GSJ="$GS/java/io/chaldeaprjkt/gamespace"
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"

if [ ! -d "$GSJ" ]; then
  echo "   *** FATAL: GameSpace source not found at $GSJ"
  exit 1
fi

# 19a: the three new files (kept whole in the recipe rather than heredoc'd)
cp "$HERE/gamespace/ChargeUtils.kt"       "$GSJ/utils/ChargeUtils.kt"
cp "$HERE/gamespace/BypassChargeTile.kt"  "$GSJ/widget/tiles/BypassChargeTile.kt"
cp "$HERE/gamespace/ic_charge_bypass.xml" "$GS/res/drawable/ic_charge_bypass.xml"
echo "   ChargeUtils.kt / BypassChargeTile.kt / ic_charge_bypass.xml staged"

# 19b: the surgical edits to existing GameSpace files. One python pass, each
# edit guarded on its own marker so re-running is safe.
python3 - "$GS" <<'EOP'
import sys, os
gs = sys.argv[1]
gsj = os.path.join(gs, "java/io/chaldeaprjkt/gamespace")

def patch(path, marker, anchor, addition, after=True, count=1):
    """Insert `addition` around the first `anchor`, unless `marker` is present."""
    with open(path) as f:
        src = f.read()
    # parent dir included: layout/tiles.xml and layout-land/tiles.xml are two
    # different files and a bare basename makes their log lines identical.
    name = "%s/%s" % (os.path.basename(os.path.dirname(path)), os.path.basename(path))
    if marker in src:
        print("   %s: already patched" % name)
        return
    if anchor not in src:
        raise SystemExit("FATAL: anchor not found in %s:\n%r" % (path, anchor))
    new = anchor + addition if after else addition + anchor
    with open(path, "w") as f:
        f.write(src.replace(anchor, new, count))
    print("   %s: patched" % name)

# --- AppSettings: the persisted user preference ---
patch(
    os.path.join(gsj, "data/AppSettings.kt"),
    "chargeBypass",
    """    var lockGesture
        get() = db.getBoolean(KEY_LOCK_GESTURE, false)
        set(value) = db.edit().putBoolean(KEY_LOCK_GESTURE, value).apply()
""",
    """
    var chargeBypass
        get() = db.getBoolean(KEY_CHARGE_BYPASS, false)
        set(value) = db.edit().putBoolean(KEY_CHARGE_BYPASS, value).apply()
""",
)
# NOTE the marker: it must be the DECLARATION, not the bare name. Guarding on
# "KEY_CHARGE_BYPASS" matched the getter/setter the patch above had just written,
# so this edit silently skipped itself and left the constant undefined -- the
# same own-goal step 13 hit. A guard must never match another step's output.
patch(
    os.path.join(gsj, "data/AppSettings.kt"),
    "const val KEY_CHARGE_BYPASS",
    '        const val KEY_LOCK_GESTURE = "gamespace_lock_gesture"\n',
    '        const val KEY_CHARGE_BYPASS = "gamespace_charge_bypass"\n',
)

# --- Hilt: provide ChargeUtils ---
patch(
    os.path.join(gsj, "utils/di/MainModule.kt"),
    "ChargeUtils",
    "import io.chaldeaprjkt.gamespace.utils.GameModeUtils\n",
    "import io.chaldeaprjkt.gamespace.utils.ChargeUtils\n",
    after=False,
)
patch(
    os.path.join(gsj, "utils/di/MainModule.kt"),
    "provideChargeUtils",
    """    @Provides
    @Singleton
    fun provideScreenUtils(@ApplicationContext context: Context) = ScreenUtils(context)
""",
    """
    @Provides
    @Singleton
    fun provideChargeUtils() = ChargeUtils()
""",
)
patch(
    os.path.join(gsj, "utils/di/ServiceViewEntryPoint.kt"),
    "ChargeUtils",
    "import io.chaldeaprjkt.gamespace.utils.GameModeUtils\n",
    "import io.chaldeaprjkt.gamespace.utils.ChargeUtils\n",
    after=False,
)
patch(
    os.path.join(gsj, "utils/di/ServiceViewEntryPoint.kt"),
    "chargeUtils()",
    "    fun screenUtils(): ScreenUtils\n",
    "    fun chargeUtils(): ChargeUtils\n",
)

# --- SessionService: apply at game start, ALWAYS restore at session end ---
sess = os.path.join(gsj, "gamebar/SessionService.kt")
patch(
    sess,
    "import io.chaldeaprjkt.gamespace.utils.ChargeUtils",
    "import io.chaldeaprjkt.gamespace.utils.GameModeUtils\n",
    "import io.chaldeaprjkt.gamespace.utils.ChargeUtils\n",
    after=False,
)
patch(
    sess,
    "lateinit var chargeUtils",
    """    @Inject
    lateinit var screenUtils: ScreenUtils
""",
    """
    @Inject
    lateinit var chargeUtils: ChargeUtils
""",
)
patch(
    sess,
    "chargeUtils.bypass = appSettings.chargeBypass",
    "            screenUtils.lockGesture = appSettings.lockGesture\n",
    "            chargeUtils.bypass = appSettings.chargeBypass\n",
)
# The restore is the safety-critical half: leaving the cell disconnected after
# the game exits would look exactly like "my phone stopped charging".
patch(
    sess,
    "chargeUtils.bypass = false",
    "        screenUtils.unbind()\n",
    "        chargeUtils.bypass = false\n",
)

# --- the tile in the game-bar panel: BOTH layouts ---
# res/layout/tiles.xml is columnCount=2 (the 6th tile makes it 3 even rows) and
# res/layout-land/tiles.xml is a SEPARATE file at columnCount=3 (2 even rows).
# Landscape is the one that matters: a game runs landscape, so patching only the
# portrait file ships a tile that is invisible in the exact situation the
# feature exists for. That is what happened -- the tile was verified on hardware
# in portrait on 2026-07-29 and reported missing in-game three builds later.
# The NotificationTile anchor is byte-identical in both files.
for _tiles in ("res/layout/tiles.xml", "res/layout-land/tiles.xml"):
    patch(
        os.path.join(gs, _tiles),
        "BypassChargeTile",
        """    <io.chaldeaprjkt.gamespace.widget.tiles.NotificationTile
        android:layout_width="wrap_content"
        android:layout_height="wrap_content" />
""",
        """
    <io.chaldeaprjkt.gamespace.widget.tiles.BypassChargeTile
        android:layout_width="wrap_content"
        android:layout_height="wrap_content" />
""",
    )

# --- string ---
patch(
    os.path.join(gs, "res/values/strings.xml"),
    "bypass_charge_title",
    '    <string name="stay_awake_title">Stay awake</string>\n',
    '    <string name="bypass_charge_title">Bypass charging</string>\n',
)
EOP

# 19b-verify: the tile must be in BOTH layouts. Missing from layout-land/ is not
# a cosmetic gap -- it is a tile that does not exist while you are in a game.
for _l in layout layout-land; do
  grep -q "BypassChargeTile" "$GS/res/$_l/tiles.xml" || {
    echo "   *** FATAL: BypassChargeTile missing from res/$_l/tiles.xml"; exit 1; }
done
echo "   tile present in portrait AND landscape layouts"

# 19c: sepolicy -- the one rule the whole feature needs.
if ! grep -q "sysfs_aichg_file" "$SEPOL/system_app.te" 2>/dev/null; then
  cat >> "$SEPOL/system_app.te" <<'EOT'

# GameSpace's bypass-charging tile. GameSpace is platform-signed with
# sharedUserId=android.uid.system, so it lands in system_app (seapp_contexts:146)
# rather than priv_app -- which matters, since priv_app.te:230 neverallows
# priv_app setting any property at all.
#
# The node is /sys/devices/platform/charger/tran_aichg_disable_charger. It is
# already labeled sysfs_aichg_file by the device file_contexts and is mode 0666,
# but carried NO allow rule anywhere, so nothing except root could ever write it
# -- which is why the manual verification only worked from a rooted shell.
#
# Read access is included on purpose: the tile reads the node back so its UI
# reflects the real hardware state rather than a remembered value.
allow system_app sysfs_aichg_file:file rw_file_perms;
EOT
  echo "   system_app -> sysfs_aichg_file rw allow added"
else
  echo "   system_app sysfs_aichg_file allow already present"
fi

# --- step 20: the device's real retail name in About phone ------------------
# crDroid's AboutDeviceNamePreferenceController builds the "Device" row as
#   SystemProperties.get("ro.product.marketname", manufacturer + " " + MODEL)
#     + " | " + ro.product.device
# We never set ro.product.marketname, so it fell back to the concatenation and
# rendered "ITEL itel S666LN | itel-S666LN" -- the brand twice, in two different
# cases, because itel's own stock values are manufacturer=ITEL and
# model="itel S666LN" (the brand is already inside the model string).
#
# The fix is NOT an invention: stock declares the retail name itself, as
# ro.product.{product,system_ext}.tran.device.name.default = "itel RS4"
# (harvested from build 251212V1661). We surface that same value under the
# property crDroid actually reads, so the row becomes "itel RS4 | itel-S666LN".
# Verified live on-device with resetprop before being made permanent.
#
# This is display-only and does NOT touch identity: Build.MODEL, brand, device,
# manufacturer and the fingerprint are all unchanged, so e-KYC and Play
# Integrity see exactly what they saw before.
#
# It goes in the raw TARGET_SYSTEM_PROP file rather than PRODUCT_*_PROPERTIES
# because the value contains a SPACE, and product-property entries are
# whitespace-separated (the value would split into two bogus entries).
echo "== step 20: real retail name in About phone =="
SYSPROP="$TREE/device/itel/S666LN/configs/properties/system.prop"
if [ ! -f "$SYSPROP" ]; then
  echo "   *** FATAL: $SYSPROP missing (TARGET_SYSTEM_PROP source)"
  exit 1
fi
if grep -q '^ro\.product\.marketname=' "$SYSPROP"; then
  echo "   marketname already set ($(grep -m1 '^ro\.product\.marketname=' "$SYSPROP" | cut -d= -f2-))"
else
  cat >> "$SYSPROP" <<'EOT'

# Retail name for About phone. Without it crDroid falls back to
# manufacturer + " " + MODEL and shows "ITEL itel S666LN", since itel's stock
# model string already contains the brand. Value is stock's own
# ro.product.*.tran.device.name.default from build 251212V1661 -- display only,
# no identity property is affected.
ro.product.marketname=itel RS4
EOT
  echo "   ro.product.marketname=itel RS4 added to system.prop"
fi

# --- step 21: let the Trustonic keybox check actually run -------------------
# PROVEN BROKEN ON DEVICE (2026-07-29). The vendor blobs ship
#   /vendor/bin/kmsetkey_ca.trustonic          (the Trustonic keymaster set-key CA)
#   /vendor/etc/init/trustonic.mc_kmsetkey_ca.rc
# whose service is literally named trustonic_check_keybox_service and runs
# "kmsetkey_ca.trustonic -c" (check keybox) at late_start. The lineage-20.0 device
# tree ships NO sepolicy for it, so under enforcing init refuses it outright:
#
#   init: Could not ctl.start for 'trustonic_check_keybox_service':
#   File /vendor/bin/kmsetkey_ca.trustonic (labeled "u:object_r:vendor_file:s0") has
#   incorrect label or no domain transition from u:r:init:s0 to another SELinux
#   domain defined.
#
# Exactly the pnpmgr failure mode (step 7), this time on the Google-attestation
# keybox path. Consequence measured on the running build: the property the binary
# sets, vendor.tee.googlekey.status, is EMPTY -- the keybox status is never
# established on any boot, even though keymint-trustonic itself is running and
# ro.hardware.kmsetkey=trustonic.
#
# HONESTY NOTE: this does NOT by itself explain losing MEETS_STRONG_INTEGRITY --
# the same gap existed on 2026-07-28 when STRONG was observed, since that build was
# already enforcing. It is a real defect on the attestation path and worth fixing on
# its own merits; do not record it as the STRONG root cause without evidence.
#
# Backported from the device tree's own lineage-23.2 branch
# (sepolicy/vendor/trustonic_kmsetkey_ca.te), with two A13 adaptations:
#  * that branch does set_prop(..., vendor_mtk_trustonic_tee_prop), but on A13
#    "vendor.tee." is not labeled anywhere, so it would resolve to
#    vendor_default_prop -- and set_prop on THAT is neverallowed
#    (system/sepolicy/public/domain.te:557), which fails the build outright. The
#    property_contexts entry below gives it the real MTK type, which already exists
#    at device/mediatek/sepolicy_vndr/bsp/non_plat/property.te:86.
#  * this device runs keymint (vendor.keymint-trustonic), so hal_keymint is granted
#    alongside hal_keymaster.
echo "== step 21: Trustonic keybox check service =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"
KMBIN="$TREE/vendor/itel/S666LN/proprietary/vendor/bin/kmsetkey_ca.trustonic"
if [ ! -f "$KMBIN" ]; then
  echo "   WARN: $KMBIN missing; skipping (vendor blobs not staged?)"
else
  if [ ! -f "$SEPOL/trustonic_kmsetkey_ca.te" ]; then
    cat > "$SEPOL/trustonic_kmsetkey_ca.te" <<'EOT'
# Trustonic keymaster set-key CA. Its init service (trustonic_check_keybox_service,
# /vendor/etc/init/trustonic.mc_kmsetkey_ca.rc) runs "kmsetkey_ca.trustonic -c" to
# check the Google attestation keybox and publish vendor.tee.googlekey.status.
# Without a domain of its own, init refuses to start it at all under enforcing, so
# the keybox is never checked and that property stays empty on every boot.
# Backported from this device tree's lineage-23.2 branch.
type trustonic_kmsetkey_ca, domain;
type trustonic_kmsetkey_ca_exec, exec_type, file_type, vendor_file_type;

init_daemon_domain(trustonic_kmsetkey_ca)

# vendor.tee.googlekey.status -- see property_contexts; the MTK type is used rather
# than vendor_default_prop, which is neverallowed for set.
set_prop(trustonic_kmsetkey_ca, vendor_mtk_trustonic_tee_prop)

# The keybox lives on the persist partition.
allow trustonic_kmsetkey_ca mnt_vendor_file:dir search;
allow trustonic_kmsetkey_ca persist_data_file:dir search;
allow trustonic_kmsetkey_ca persist_data_file:file { getattr open read };
allow trustonic_kmsetkey_ca ut_keymaster_device:chr_file rw_file_perms;

# A13 runs keymint here; keymaster is kept for parity with the upstream rule.
hal_client_domain(trustonic_kmsetkey_ca, hal_keymaster)
hal_client_domain(trustonic_kmsetkey_ca, hal_keymint)
EOT
    echo "   trustonic_kmsetkey_ca.te created"
  else
    echo "   trustonic_kmsetkey_ca.te already present"
  fi

  if ! grep -q "kmsetkey_ca" "$SEPOL/file_contexts" 2>/dev/null; then
    printf '\n/vendor/bin/kmsetkey_ca\\.trustonic                                               u:object_r:trustonic_kmsetkey_ca_exec:s0\n' >> "$SEPOL/file_contexts"
    echo "   kmsetkey_ca.trustonic labeled"
  fi

  if ! grep -q "^vendor\.tee\." "$SEPOL/property_contexts" 2>/dev/null; then
    printf '\nvendor.tee.                                 u:object_r:vendor_mtk_trustonic_tee_prop:s0\n' >> "$SEPOL/property_contexts"
    echo "   vendor.tee. labeled vendor_mtk_trustonic_tee_prop"
  fi
fi

# --- step 22: clear the remaining enforcing denials --------------------------
# Harvested from a clean boot of the step-21 build (dmesg, shell noise excluded):
#   75x gmscore_app -> traced_producer_socket:sock_file write   <- the spam
#    9x pnpmgr      -> property_socket:sock_file write
#    9x gmscore_app -> {adbd_prop,system_adbd_prop}:file read
#    8x system_suspend -> sysfs_batteryinfo:file read
#    6x system_app  -> sysfs_zram:dir search
#    3x pnpmgr      -> {proc:file, cgroup:{dir,file}} read
#    1x mnld        -> default_prop:file read
#    1x fsck_untrusted -> sysfs_devices_block:dir search
# None were breakage; the device ran fine. They are fixed because the 75x storm
# drowns real denials in dmesg and costs wakeups on a battery device -- the same
# argument that justified the pnpmgr/vndbinder fix in step 5.
#
# WHICH FILE A RULE GOES IN IS NOT COSMETIC. Vendor policy cannot reference
# types declared in system/sepolicy/private (the build fails with an unknown
# type), so anything touching system_suspend, adbd_prop or system_adbd_prop must
# live in SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS (BoardConfig.mk:163 -> sepolicy/private),
# while vendor domains like pnpmgr and mnld stay in sepolicy/vendor. Checked each
# type's declaration site before writing the rule.
echo "== step 22: remaining enforcing denials =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"
SEPRIV="$TREE/device/itel/S666LN/sepolicy/private"

# -- pnpmgr's properties. Step 7 deliberately left this unresolved because the
# -- denial names only the socket, not the property. Recovered the names from the
# -- binary itself (strings /vendor/bin/pnpmgr), so it can now have a real type
# -- instead of vendor_default_prop, which is neverallowed for set.
if ! grep -q "vendor_pnpmgr_prop" "$SEPOL/property.te" 2>/dev/null; then
  printf '\n# vendor.prop.pnp.* and vendor.sys.pnpmgr.state, written by /vendor/bin/pnpmgr\n# (names recovered from the binary; the avc only ever named property_socket).\nvendor_internal_prop(vendor_pnpmgr_prop)\n' >> "$SEPOL/property.te"
  echo "   vendor_pnpmgr_prop type added"
fi
if ! grep -q "vendor.prop.pnp." "$SEPOL/property_contexts" 2>/dev/null; then
  printf '\nvendor.prop.pnp.                            u:object_r:vendor_pnpmgr_prop:s0\nvendor.sys.pnpmgr.                          u:object_r:vendor_pnpmgr_prop:s0\n' >> "$SEPOL/property_contexts"
  echo "   pnpmgr properties labeled"
fi
if ! grep -q "vendor_pnpmgr_prop" "$SEPOL/pnpmgr.te" 2>/dev/null; then
  cat >> "$SEPOL/pnpmgr.te" <<'EOT'

# Its own properties (resolves the property_socket denial step 7 left open).
set_prop(pnpmgr, vendor_pnpmgr_prop)

# Reads its own cgroup/proc state while tuning.
allow pnpmgr proc:file r_file_perms;
allow pnpmgr cgroup:dir r_dir_perms;
allow pnpmgr cgroup:file r_file_perms;
EOT
  echo "   pnpmgr: property + proc/cgroup rules added"
fi

# -- vendor-side leftovers
if ! grep -q "sysfs_zram" "$SEPOL/system_app.te" 2>/dev/null; then
  printf '\n# Settings/Storage enumerates zram for the memory UI.\nallow system_app sysfs_zram:dir search;\n' >> "$SEPOL/system_app.te"
  echo "   system_app -> sysfs_zram search added"
fi
if ! grep -q "sysfs_devices_block" "$SEPOL/fsck.te" 2>/dev/null; then
  printf '\n# fsck_untrusted walks /sys/devices/.../block when checking a volume.\nallow fsck_untrusted sysfs_devices_block:dir search;\n' >> "$SEPOL/fsck.te"
  echo "   fsck_untrusted -> sysfs_devices_block search added"
fi
if [ ! -f "$SEPOL/mnld.te" ]; then
  cat > "$SEPOL/mnld.te" <<'EOT'
# The MTK location daemon probes a property that has no type of its own, so the
# lookup lands on default_prop. Silenced rather than granted: reading
# default_prop wholesale is far broader than anything mnld legitimately needs,
# and GPS works without it (lock confirmed on-device).
dontaudit mnld default_prop:file read;
EOT
  echo "   mnld.te created (dontaudit default_prop)"
fi

# -- system_ext private side (vendor policy cannot see these types)
if ! grep -q "sysfs_batteryinfo:file" "$SEPRIV/system_suspend.te" 2>/dev/null; then
  printf '\n# NOT an oversight that the rule above grants only the DIR: reading these FILES\n# from coredomain is NEVERALLOWED (public/domain.te:1316, full_treble_only) --\n# "Platform must not have access to sysfs_batteryinfo, but should do it via\n# health HAL". Granting it fails the build outright. Silence it instead;\n# system_suspend works without it and the health HAL is the sanctioned path.\ndontaudit system_suspend sysfs_batteryinfo:file r_file_perms;\n' >> "$SEPRIV/system_suspend.te"
  echo "   system_suspend -> sysfs_batteryinfo:file dontaudit added (allow is neverallowed)"
fi
if [ ! -f "$SEPRIV/gmscore_app.te" ]; then
  cat > "$SEPRIV/gmscore_app.te" <<'EOT'
# GMS repeatedly tries to register as a Perfetto tracing producer and to read the
# adb state properties. Both are refused on stock too; AOSP silences rather than
# grants them, and so do we -- an app has no business writing the tracing
# producer socket, and the adb props are deliberately system-internal.
# Silencing matters here: the traced_producer attempt fired ~every 2-4s (75 hits
# in ~3 minutes), which buries genuine denials in dmesg and wakes the device.
dontaudit gmscore_app traced_producer_socket:sock_file write;
dontaudit gmscore_app adbd_prop:file read;
dontaudit gmscore_app system_adbd_prop:file read;
EOT
  echo "   gmscore_app.te created (3 dontaudits, kills the 75x storm)"
fi
if [ ! -f "$SEPRIV/untrusted_app.te" ]; then
  cat > "$SEPRIV/untrusted_app.te" <<'EOT'
# Only ever seen because /data/local/tmp had adb-pushed test files during
# development; a shipped device will not hit this. Silenced so it cannot be
# mistaken for a real finding later.
dontaudit untrusted_app shell_test_data_file:dir search;
EOT
  echo "   untrusted_app.te created (adb test noise)"
fi

# --- step 23: the last crumbs ------------------------------------------------
# Harvested from a clean boot of the step-22 build. Only SIX denial events total
# (down from 100+), and every one is a legitimate READ that was simply never
# granted. Causes identified from the avc `comm=` and `name=` fields rather than
# guessed:
#   4x system_app     -> sysfs_zram:file          comm=ndroid.settings, name=mm_stat
#   1x fsck_untrusted -> sysfs_devices_block:file comm=fsck.exfat,      name=start
#   1x mediaserver    -> vendor_default_prop:file comm=binder:778_1
#
# TWO OF THESE ARE MY OWN INCOMPLETE RULES FROM STEP 22. I granted `dir search`
# on sysfs_zram and sysfs_devices_block; the directory denial had been MASKING a
# file-read denial behind it, which only surfaced once the search succeeded.
# Lesson, and the mirror image of the system_suspend one in step 22: after
# granting a dir permission, re-check for the file permission behind it -- one
# denial can hide another, so "the denial is gone" is not "the operation works".
#
# The fsck -> block_device:blk_file denial seen on the previous boot did NOT
# recur here (it was a one-off storage check), so it is deliberately not granted:
# no rule without an observation to justify it.
echo "== step 23: the last crumbs =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"

if ! grep -q "sysfs_zram:file" "$SEPOL/system_app.te" 2>/dev/null; then
  printf '\n# Settings reads /sys/block/zram0/mm_stat for the memory UI. The dir search\n# granted in step 22 was not enough on its own.\nallow system_app sysfs_zram:file r_file_perms;\n' >> "$SEPOL/system_app.te"
  echo "   system_app -> sysfs_zram:file read added"
else
  echo "   system_app sysfs_zram:file already present"
fi

if ! grep -q "sysfs_devices_block:file" "$SEPOL/fsck.te" 2>/dev/null; then
  printf '\n# fsck.exfat reads the partition start offset (.../block/*/start). Same story:\n# the dir search alone left the file read denied.\nallow fsck_untrusted sysfs_devices_block:file r_file_perms;\n' >> "$SEPOL/fsck.te"
  echo "   fsck_untrusted -> sysfs_devices_block:file read added"
else
  echo "   fsck_untrusted sysfs_devices_block:file already present"
fi

if ! grep -q "vendor_default_prop" "$SEPOL/mediacodec.te" 2>/dev/null; then
  cat >> "$SEPOL/mediacodec.te" <<'EOT'

# mediaserver reads an untyped vendor property (codec configuration).
# It is SILENCED, not granted: reading vendor_default_prop is neverallowed for
# coredomain too, not just setting it. domain.te:557 covers
# "vendor_default_prop:property_service set", but there is a SEPARATE neverallow
# on the file class -- an allow here fails the build with
#   neverallow ... vendor_default_prop (file (ioctl read write ...))
# The property has no type of its own to target more narrowly, and mediaserver
# works without it, so silencing is the only correct option.
dontaudit mediaserver vendor_default_prop:file r_file_perms;
EOT
  echo "   mediaserver -> vendor_default_prop read added"
else
  echo "   mediaserver vendor_default_prop already present"
fi

# --- step 24: tranfs is labeled on the WRONG PARTITION ----------------------
# Found chasing the last denial (e2fsck reading name="sdc64" as generic
# block_device). The device tree labels by hardcoded partition NUMBER:
#     /dev/block/sdc62    u:object_r:tranfs_block_device:s0
# but on this hardware the numbering is:
#     /dev/block/sdc62 -> tee_b        <-- gets tranfs_block_device (WRONG)
#     /dev/block/sdc64 -> tranfs       <-- left as generic block_device
#
# So this is not merely a missing label. The rules written for tranfs are aimed
# at the TEE partition's B slot, in particular
#     init.te:2   allow init tranfs_block_device:blk_file { read relabelto };
# which hands init read/relabel on tee_b rather than on tranfs. The visible
# symptom was only the e2fsck denial, because fsck.te's
# "allow fsck tranfs_block_device:blk_file rw_file_perms" could never match the
# real tranfs.
#
# Fixed by labeling through the by-name symlink -- the form the tree already
# uses for lk, gz, dpm, odm, oem and scp -- so it survives any renumbering
# between firmware revisions. The wrong sdc62 line is removed rather than left
# alongside, since leaving it would keep tee_b mislabeled.
echo "== step 24: label tranfs by-name, not by partition number =="
FCTX="$TREE/device/itel/S666LN/sepolicy/vendor/file_contexts"
if grep -q "^/dev/block/by-name/tranfs" "$FCTX" 2>/dev/null; then
  echo "   tranfs already labeled by-name"
else
  python3 - "$FCTX" <<'EOP'
import re, sys
p = sys.argv[1]
s = open(p).read()
# drop the hardcoded-number line (it points at tee_b on this hardware)
s2, n = re.subn(r'(?m)^/dev/block/sdc62\s+u:object_r:tranfs_block_device:s0\n', '', s)
if n:
    print("   removed the sdc62 line (that partition is tee_b here)")
else:
    print("   WARN: sdc62 tranfs line not found; leaving as-is")
    s2 = s
if not s2.endswith("\n"):
    s2 += "\n"
s2 += "/dev/block/by-name/tranfs                                                       u:object_r:tranfs_block_device:s0\n"
open(p, "w").write(s2)
print("   tranfs labeled via by-name")
EOP
fi

# --- step 25: the layer step 24 uncovered ------------------------------------
# Clearing one denial keeps exposing the next one behind it. After step 24:
#   6x fsck -> tmpfs:lnk_file { read }   comm=e2fsck, name="tranfs"
#   1x vold -> persist_data_file:dir { read }  name="/", dev=sdc18
#
# THE FIRST ONE IS CAUSED BY STEP 24 ITSELF, and that is worth being explicit
# about: labeling tranfs through /dev/block/by-name/tranfs means e2fsck now
# resolves it through a SYMLINK on tmpfs, and fsck.te only ever granted
# `tmpfs:blk_file` -- never `tmpfs:lnk_file`. So the fix created a new,
# narrower requirement. That is not a regression, it is the by-name path
# actually being taken for the first time; before step 24 fsck never got far
# enough to need it.
#
# The vold one is unrelated and was simply behind the noise: vold stats the
# /persist mount root (sdc18) while enumerating volumes.
echo "== step 25: what step 24 uncovered =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"

if ! grep -q "tmpfs:lnk_file" "$SEPOL/fsck.te" 2>/dev/null; then
  printf '\n# e2fsck resolves /dev/block/by-name/tranfs, which is a symlink on tmpfs.\n# Required by the by-name labeling in step 24; blk_file alone is not enough.\nallow fsck tmpfs:lnk_file r_file_perms;\n' >> "$SEPOL/fsck.te"
  echo "   fsck -> tmpfs:lnk_file read added (needed by step 24's by-name label)"
else
  echo "   fsck tmpfs:lnk_file already present"
fi

if [ ! -f "$SEPOL/vold.te" ]; then
  cat > "$SEPOL/vold.te" <<'EOT'
# vold reads the /persist mount root (sdc18) while enumerating volumes.
# SILENCED, not granted: persist_data_file is a VENDOR data type and vold is
# coredomain, so the access is neverallowed outright (the Treble boundary --
# coredomain must not reach vendor data files). Both types being *visible* to
# vendor policy says nothing about the access being *permitted*; an allow here
# fails the build with
#   neverallow ... (dir (ioctl read write create getattr ... search))
# vold enumerates volumes fine without it.
dontaudit vold persist_data_file:dir r_dir_perms;
EOT
  echo "   vold.te created (persist_data_file:dir read)"
else
  echo "   vold.te already present"
fi

# --- step 26: the last three ------------------------------------------------
# After step 25 the boot is down to THREE denial events, one each:
#   init   -> logcat_exec:file { getattr }            path=/system/bin/logcat
#   atrace -> debugfs_tracing_debug:file { write }    name=enable
#   init   -> hal_fingerprint_default:process { ptrace }
# Checked the neverallows for each target type FIRST this time (the mistake that
# got six rules rejected earlier was assuming type visibility meant permission):
# none of the three is neverallowed, so all could be granted -- but only the
# first one should be.
echo "== step 26: the last three =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"

if ! grep -q "logcat_exec" "$SEPOL/init.te" 2>/dev/null; then
  cat >> "$SEPOL/init.te" <<'EOT'

# init stats /system/bin/logcat for the vendor "boot_log" service
# (vendor/etc/init/*.rc). A vendor rc naming a SYSTEM binary is the unusual part;
# init legitimately needs getattr on any service executable it is asked to start.
allow init logcat_exec:file getattr;
EOT
  echo "   init -> logcat_exec:file getattr added"
else
  echo "   init logcat_exec already present"
fi

if [ ! -f "$SEPOL/atrace.te" ]; then
  cat > "$SEPOL/atrace.te" <<'EOT'
# atrace enables a tracefs event at boot. SILENCED rather than granted: atrace is
# a debugging tool, this is a `user` build, and the only consequence of the denial
# is that one trace category stays off. Granting write on debugfs tracing to make
# a log line disappear would be the wrong trade.
dontaudit atrace debugfs_tracing_debug:file write;
EOT
  echo "   atrace.te created (dontaudit tracefs write)"
else
  echo "   atrace.te already present"
fi

if ! grep -q "hal_fingerprint_default:process" "$SEPOL/init.te" 2>/dev/null; then
  cat >> "$SEPOL/init.te" <<'EOT'

# init tries to ptrace the fingerprint HAL, almost certainly while collecting
# diagnostics as that process exits -- the Goodix HAL is known to exit once after
# a successful enroll (see JOURNAL, 2026-07-28). SILENCED, not granted: ptrace on
# a HAL is real privilege, nothing depends on it succeeding, and init reaps the
# process either way.
dontaudit init hal_fingerprint_default:process ptrace;
EOT
  echo "   init -> hal_fingerprint_default ptrace dontaudit added"
fi

# --- step 27: camerahalserver traversing /data --------------------------------
# Seen on a clean boot once the camera initialises:
#   3x mtk_hal_camera -> system_data_file:dir { search }   comm=camerahalserver
#
# GRANTABLE, and worth reading the neverallow carefully to see why. domain.te:883
# looks like it forbids exactly this:
#     neverallow { domain -appdomain -coredomain ... }
#       { system_data_file }:dir ~{ getattr search };
# but the target permission set is NEGATED (`~`): everything EXCEPT getattr and
# search. Vendor domains are deliberately permitted to TRAVERSE /data; what they
# may not do is read, write or enumerate it. `search` alone is the sanctioned
# case, so this is an allow rather than a dontaudit.
echo "== step 27: camerahalserver /data traversal =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"

if ! grep -q "system_data_file:dir" "$SEPOL/mtk_hal_camera.te" 2>/dev/null; then
  cat >> "$SEPOL/mtk_hal_camera.te" <<'EOT'

# camerahalserver traverses /data to reach its own storage. Only `search` is
# granted: domain.te:883 negates its permission set (~{ getattr search }), so
# traversal is the sanctioned vendor case while read/write/enumerate stay barred.
allow mtk_hal_camera system_data_file:dir search;
EOT
  echo "   mtk_hal_camera -> system_data_file:dir search added"
else
  echo "   mtk_hal_camera system_data_file already present"
fi

# --- step 28: LineageSetupWizard WizardManager race ---------------------------
# OBSERVED ON DEVICE 2026-07-30: setup completed but threw on the way out --
#   org.lineageos.setupwizard  FATAL EXCEPTION: main
#   ActivityNotFoundException: No Activity found to handle
#     Intent { act=com.android.wizard.LOAD }
#   at SetupWizardActivity.onCreate(SetupWizardActivity.java:71)
# and, because the wizard disables the status bar and nav buttons while it owns
# the screen, it died before restoring them: mDisabled1=0x3a50000
# (DISABLE_EXPAND|HOME|RECENT|SEARCH|CLOCK|NOTIFICATION_ALERTS). The user is left
# with no Quick Settings pull-down and only a Back button until a reboot.
#
# NOT caused by dropping Google's SetupWizard in step 16 -- I assumed that first
# and it is wrong. LineageSetupWizard declares its OWN handler for that action
# (AndroidManifest.xml: .wizardmanager.WizardManager, android:enabled="false"),
# and enables it one line before use:
#     SetupWizardUtils.enableComponent(this, WizardManager.class);   // async
#     startActivity(new Intent(ACTION_LOAD));                        // race
# enableComponent() -> setComponentEnabledSetting(..., DONT_KILL_APP), whose new
# state is not reliably visible to intent resolution by the very next statement.
# This is an upstream bug and can bite any device on a first boot after a wipe.
#
# The fix is deliberately conservative, because breaking first-boot setup would
# be far worse than the crash it prevents: the happy path is untouched, and only
# the failure path changes -- retry once with an EXPLICIT component, and if even
# that fails, finish setup cleanly instead of throwing. Finishing is what already
# happens today anyway; it just currently costs an FC dialog and a wedged UI.
echo "== step 28: LineageSetupWizard WizardManager race =="
SWA="$TREE/packages/apps/SetupWizard/src/org/lineageos/setupwizard/SetupWizardActivity.java"
if [ ! -f "$SWA" ]; then
  echo "   WARN: $SWA missing; skipping"
elif grep -q "ActivityNotFoundException" "$SWA"; then
  echo "   already patched"
else
  python3 - "$SWA" <<'EOP'
import sys
p = sys.argv[1]
s = open(p).read()

# 1. imports
anchor_imp = "import android.content.Intent;\n"
if anchor_imp not in s:
    raise SystemExit("FATAL: import anchor not found")
s = s.replace(anchor_imp,
              "import android.content.ActivityNotFoundException;\n"
              "import android.content.ComponentName;\n"
              + anchor_imp, 1)

# 2. guard the startActivity that races the component enable
anchor = """            intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(intent);
            finish();"""
if anchor not in s:
    raise SystemExit("FATAL: startActivity anchor not found")
replacement = """            intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | FLAG_GRANT_READ_URI_PERMISSION);
            // enableComponent() above is setComponentEnabledSetting(DONT_KILL_APP), whose
            // result is not reliably visible to intent resolution this soon, so the
            // implicit ACTION_LOAD can fail to resolve. Retry explicitly, and if the
            // wizard genuinely cannot start, finish setup rather than throwing --
            // crashing here leaves the status bar and nav buttons disabled.
            try {
                startActivity(intent);
            } catch (ActivityNotFoundException e) {
                Log.w(TAG, "WizardManager did not resolve; retrying explicitly", e);
                intent.setComponent(new ComponentName(this, WizardManager.class));
                try {
                    startActivity(intent);
                } catch (ActivityNotFoundException e2) {
                    Log.e(TAG, "WizardManager unavailable; finishing setup", e2);
                    SetupWizardUtils.finishSetupWizard(this);
                }
            }
            finish();"""
s = s.replace(anchor, replacement, 1)
open(p, "w").write(s)
print("   SetupWizardActivity.java patched")
EOP
fi

# --- step 29: the boot-time denials dmesg was hiding --------------------------
# METHOD FIX FIRST, because it invalidated an earlier "zero denials" claim:
# `dmesg` is a RING BUFFER. On this kernel it holds ~31k lines and wraps within a
# couple of hours, so boot-time avc records scroll out and a late check reads an
# empty window as a clean system. **Use `logcat -b all | grep "avc: denied"`**,
# which retains them, or only trust dmesg within minutes of boot.
#
# The six that were actually there (all audit(0.0:N) — early boot):
#   1x init            -> tranfs_block_device:lnk_file { relabelto }
#   3x dexoptanalyzer  -> privapp_data_file:dir { search }
#   1x epdg_wod        -> self:udp_socket { ioctl }   (0x8916 = SIOCGIFADDR)
#
# THE FIRST IS A CONSEQUENCE OF STEP 24. Labeling /dev/block/by-name/tranfs means
# init tries to relabel the SYMLINK too, and init.te grants tranfs_block_device
# on blk_file only. Worth being precise about the impact: the real device
# /dev/block/sdc64 IS correctly labeled tranfs_block_device, and access control
# follows the target, not the link -- so nothing was ever misprotected. This is
# tidiness, not a security gap.
echo "== step 29: boot-time denials =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"
SEPRIV="$TREE/device/itel/S666LN/sepolicy/private"

if ! grep -q "tranfs_block_device:lnk_file" "$SEPOL/init.te" 2>/dev/null; then
  cat >> "$SEPOL/init.te" <<'EOT'

# Step 24 labels tranfs through /dev/block/by-name/tranfs, which is a symlink on
# tmpfs, so init relabels the link as well as the device. The existing grant
# covers blk_file only.
allow init tranfs_block_device:lnk_file relabelto;
EOT
  echo "   init -> tranfs_block_device:lnk_file relabelto added"
else
  echo "   init tranfs lnk_file already present"
fi

if [ ! -f "$SEPOL/epdg_wod.te" ]; then
  cat > "$SEPOL/epdg_wod.te" <<'EOT'
# The ePDG watchdog daemon issues SIOCGIFADDR (0x8916) on its own socket while
# probing interface addresses. Denied because device/mediatek/sepolicy_vndr never
# granted the ioctl. Self-directed and harmless.
allow epdg_wod self:udp_socket ioctl;
EOT
  echo "   epdg_wod.te created (self udp_socket ioctl)"
else
  echo "   epdg_wod.te already present"
fi

# dexoptanalyzer is declared in system/sepolicy/PRIVATE, so this rule cannot live
# in vendor policy -- it goes in SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS.
if [ ! -f "$SEPRIV/dexoptanalyzer.te" ]; then
  cat > "$SEPRIV/dexoptanalyzer.te" <<'EOT'
# dexoptanalyzer traverses per-app data dirs to decide whether a package needs
# re-dexopting. SILENCED rather than granted: privapp_data_file carries MLS
# categories (c512,c768), so a plain allow would not reliably satisfy the
# constraint anyway, and the only cost of the denial is that dexoptanalyzer
# falls back to a full dexopt decision -- a startup optimisation, not
# correctness. Apps install and run normally.
dontaudit dexoptanalyzer privapp_data_file:dir search;
EOT
  echo "   dexoptanalyzer.te created (dontaudit, private sepolicy)"
else
  echo "   dexoptanalyzer.te already present"
fi

# --- step 30: WITHDRAWN — GameSpace stays in the shared system_app domain -----
# This step used to carve GameSpace out of `system_app` into its own
# `gamespace_app` domain, so the bypass-charging rule would apply to one app
# instead of every platform-signed system-UID app. Raised in review by
# putrazxyo13 and correct in principle. It is WITHDRAWN, and the reasoning is
# recorded because the principle will tempt someone again.
#
# WHY IT WAS DROPPED — it broke a PUBLIC release. `system_app` is a TYPE, not an
# attribute, so a new domain inherits NOTHING and every access has to be
# rediscovered. That cost, in order:
#   1. build failure — domain was `app_domain()` but not `coredomain`, so
#      domain.te:649 treated it as a vendor app and refused a non-app_api service
#   2. on-device denial round — 7 MLS denials; needed `mlstrustedsubject`, which
#      system_app carries and which no `allow` rule can substitute for
#   3. FORCE CLOSE IN A PUBLIC BUILD (FINAL10) — the grant list was enumerated by
#      reading GameSpace's SOURCE, which cannot see services the FRAMEWORK
#      resolves on the app's behalf. `activity_task` appears nowhere in GameSpace,
#      so every startActivity() hit a null IActivityTaskManager and crashed:
#        java.lang.NullPointerException ... IActivityTaskManager.startActivity
#        at Instrumentation.execStartActivity(Instrumentation.java:1838)
#
# THE DISQUALIFYING PROPERTY: that crash produced **no SELinux denial at all**.
# This project verifies with denial sweeps, so the entire method is blind to this
# failure class — it is only findable by exercising every feature by hand. And
# more gaps were still visible against system_app.te (icon_file, statsd
# binder_call, cgroup writes, servicemanager list, anr_data_file).
#
# THE TRADE, STATED PLAINLY: the whole benefit was scoping ONE sysfs node
# (tran_aichg_disable_charger, already mode 0666) to one app, within a domain
# that is already privileged and platform-signed. That is not worth an
# open-ended reimplementation of system_app discovered by user bug reports.
#
# IF IT IS EVER REVIVED: it needs a WRITTEN FUNCTIONAL CHECKLIST run before
# release — game bar, screenshot, screen record, gesture lock, FPS overlay,
# bypass tile, session-end restore, answer/end a call from the bar, battery mode,
# and ADD A GAME — plus the attribute-shaped grant
# (`allow gamespace_app app_api_service:service_manager find;` + window_service
# + radio_service), never an allow-list of names read off the source.
echo "== step 30: WITHDRAWN — reverting to the shared system_app domain =="
SEPOL="$TREE/device/itel/S666LN/sepolicy/vendor"
SEPRIV="$TREE/device/itel/S666LN/sepolicy/private"
SEPUB="$TREE/device/itel/S666LN/sepolicy/public"

_gs_removed=0
for f in "$SEPUB/gamespace_app.te" "$SEPRIV/gamespace_app.te" "$SEPOL/gamespace_app.te"; do
  if [ -f "$f" ]; then rm -f "$f"; _gs_removed=$((_gs_removed+1)); fi
done
[ "$_gs_removed" -gt 0 ] && echo "   removed $_gs_removed gamespace_app.te file(s)"

# Drop the seapp_contexts pin so the app falls back to the system_app catch-all.
# step 30 CREATED this file and nothing else writes to it, so once the gamespace
# entry is gone the file should contain no real rules — remove it entirely rather
# than leave an orphaned comment referring to a domain that no longer exists.
if [ -f "$SEPRIV/seapp_contexts" ] && grep -q "gamespace" "$SEPRIV/seapp_contexts" 2>/dev/null; then
  python3 - "$SEPRIV/seapp_contexts" <<'EOP'
import sys, re
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'(?m)^user=system seinfo=platform name=io\.chaldeaprjkt\.gamespace .*\n?', '', s)
# strip comment lines that mention gamespace and the block introducing them
s = re.sub(r'(?m)^#.*(?:GameSpace|gamespace).*\n', '', s)
s = re.sub(r'(?m)^# catch-all at system/sepolicy/private/seapp_contexts:146.*\n', '', s)
s = re.sub(r'(?m)^# name so only this app lands in gamespace_app.*\n', '', s)
open(p, 'w').write(s)
EOP
  echo "   seapp_contexts: gamespace entry + comments removed"
fi
# If nothing but blank lines/comments survive, the file has no purpose.
if [ -f "$SEPRIV/seapp_contexts" ]; then
  if ! grep -qE '^[[:space:]]*[^#[:space:]]' "$SEPRIV/seapp_contexts"; then
    rm -f "$SEPRIV/seapp_contexts"
    echo "   seapp_contexts had no rules left -> file removed"
  fi
fi
[ ! -f "$SEPRIV/seapp_contexts" ] || [ "$(grep -c gamespace "$SEPRIV/seapp_contexts")" = "0" ] || {
  echo "   *** FATAL: gamespace still referenced in seapp_contexts"; exit 1; }

# The charger rule must be back on system_app (step 19 owns it; step 30 used to
# delete it). Re-add here so a tree that had step 30 applied is fully restored.
if ! grep -q "allow system_app sysfs_aichg_file" "$SEPOL/system_app.te" 2>/dev/null; then
  printf '\nallow system_app sysfs_aichg_file:file rw_file_perms;\n' >> "$SEPOL/system_app.te"
  echo "   system_app.te: charger rule RESTORED"
else
  echo "   system_app.te: charger rule present"
fi
[ "$(grep -c 'allow system_app sysfs_aichg_file' "$SEPOL/system_app.te")" = "1" ] || {
  echo "   *** FATAL: expected exactly one system_app charger rule"; exit 1; }
for f in "$SEPUB/gamespace_app.te" "$SEPRIV/gamespace_app.te" "$SEPOL/gamespace_app.te"; do
  [ -f "$f" ] && { echo "   *** FATAL: $f still present"; exit 1; }
done

# --- step 31: drop the Eleven music player -----------------------------------
# Operator, 2026-07-30. The defect, stated precisely rather than as "buggy":
# Eleven MISREPORTS TRACK DURATION and then crashes on it. A 6-minute song is
# shown as ~2 minutes, and when playback passes the duration it thinks the track
# has, the app force-closes. Google Files plays the same files correctly, so the
# platform decodes them fine -- this is Eleven's own duration handling.
# Decision: remove it and let users install a player of their choice (AIMP, etc.)
# from the Play Store, rather than carry a patched fork of an app upstream barely
# maintains on this branch.
#
# MEASURED, not assumed (2026-07-30, on-device + ffprobe on the pulled files):
# MediaStore's durations are CORRECT -- 376824 ms and 323904 ms for two long
# tracks, matching ffprobe's 376.824 s and 323.904 s exactly. So the scan is fine
# and the fault is inside Eleven. A replacement player (AIMP etc.) reading
# MediaStore will get the right length; nothing at the platform level needs
# fixing. (An earlier note here blamed MediaProvider's scan -- that was
# speculation and it was WRONG.)
# Also ruled out: the files are VBR but carry a proper Xing header, and a naive
# first-frame-bitrate estimate would over-state the length (19:06), not
# under-state it -- so neither of the usual VBR duration bugs explains it. The
# actual mechanism inside Eleven was NOT identified; the app is simply dropped.
#
# Eleven is pulled in by vendor/lineage/config/common_full.mk, which this device
# inherits through common_full_phone.mk, so it has to go at the source.
# PRODUCT_PACKAGES is additive and there is no clean "un-add" that survives
# inherit ordering -- a filter-out in device.mk depends on being evaluated after
# the inherit and silently no-ops if it is not.
#
# NOTHING ELSE NEEDS CHANGING. The only other reference in the whole tree is
# crDroid's App Lock allow-list (vendor/lineage/overlay/common/frameworks/base/
# core/res/res/values/config.xml, string-array config_appLockAllowedSystemApps).
# An entry there for a package that is not installed is inert -- App Lock just
# never offers it -- so the overlay is deliberately left byte-identical to
# upstream rather than carrying a needless fork.
#
# CONSEQUENCE, stated so it is a decision and not a surprise: the ROM then ships
# with NO music player, and nothing handles android.intent.action.MUSIC_PLAYER
# or category APP_MUSIC. That is acceptable ONLY because GApps is baked in, so
# Play Store is there on first boot to install one. A VANILLA=1 build has no
# such fallback and would ship with no way to play local audio out of the box.
echo "== step 31: drop the Eleven music player =="
FULLMK="$TREE/vendor/lineage/config/common_full.mk"
if [ ! -f "$FULLMK" ]; then
  echo "   *** FATAL: $FULLMK not found"
  exit 1
fi
# Guard matches the real PRODUCT_PACKAGES entry -- an indented "Eleven" followed
# by a line-continuation backslash -- not the bare word, which also appears in
# this step's own comment block. That distinction is the step-13/step-19 own-goal
# this project has now committed twice.
if grep -qE '^[[:space:]]+Eleven[[:space:]]*\\$' "$FULLMK"; then
  python3 - "$FULLMK" <<'EOP'
import sys, re
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'(?m)^[ \t]+Eleven[ \t]*\\\n', '', s)
assert s2 != s, "guard matched but substitution removed nothing"
open(p, 'w').write(s2)
EOP
  echo "   common_full.mk: Eleven removed from PRODUCT_PACKAGES"
else
  echo "   already patched (no Eleven entry in common_full.mk)"
fi
if grep -qE '^[[:space:]]+Eleven[[:space:]]*\\$' "$FULLMK"; then
  echo "   *** FATAL: Eleven still present after removal"
  exit 1
fi

# --- step 32: the logo partition is labeled on a path that does not exist -----
# Reported by a user on the public release: offline charging (charging with the
# phone powered off) shows NO animation -- just the battery logo repeating, then
# a reboot.
#
# MTK draws that animation with /system/bin/kpoc_charger, which reads the frames
# out of the LOGO PARTITION. Its policy grants exactly that:
#     allow kpoc_charger logo_block_device:blk_file { read open };
# but on this device NOTHING CARRIES THAT LABEL. Measured on hardware:
#     /dev/block/by-name/logo_a -> sdc32   u:object_r:block_device:s0
#     /dev/block/by-name/logo_b -> sdc54   u:object_r:block_device:s0
#     devices holding logo_block_device: 0   (policy references: 8, so that 0 is real)
#
# CAUSE: this is an A/B device, so the logo partition is SLOTTED, but the only
# labels that exist are for the NON-slotted path --
# device/mediatek/sepolicy_vndr/basic/non_plat/file_contexts:587
#     /dev/block/by-name/logo   u:object_r:logo_block_device:s0
# There is no /dev/block/by-name/logo on an A/B device, so the rule matches
# nothing and kpoc_charger's grant can never apply.
#
# Same FAMILY as step 24 (tranfs), different cause: step 24 was a label aimed at
# a hardcoded partition NUMBER that had moved; this is a label aimed at a
# non-slotted path on a slotted device. Both produce a grant that silently
# matches nothing. Fixed in our own file_contexts rather than by editing
# device/mediatek/sepolicy_vndr, which is a SHARED LineageOS repo.
#
# HONESTY NOTE: the missing label and the unmatchable grant are measured facts.
# That this is what produces the reboot loop is a strong inference, NOT proven --
# confirm with a pstore/last_kmsg capture from a real offline-charge attempt, or
# simply by flashing this and charging while powered off.
echo "== step 32: label the SLOTTED logo partitions =="
VFC="$TREE/device/itel/S666LN/sepolicy/vendor/file_contexts"
if ! grep -qE '^/dev/block/by-name/logo_a[[:space:]]' "$VFC" 2>/dev/null; then
  printf '\n# A/B device: the logo partition is slotted, so the non-slotted\n# /dev/block/by-name/logo label in device/mediatek/sepolicy_vndr matches nothing\n# and kpoc_charger cannot read the offline-charging animation frames.\n/dev/block/by-name/logo_a                                                       u:object_r:logo_block_device:s0\n/dev/block/by-name/logo_b                                                       u:object_r:logo_block_device:s0\n' >> "$VFC"
  echo "   logo_a / logo_b labeled logo_block_device"
else
  echo "   already patched (logo_a labeled)"
fi

# Predicted from step 29, not yet observed: labeling through /dev/block/by-name
# makes init relabel the SYMLINK too, and init.te grants blk_file only. tranfs hit
# exactly this one flash after step 24 introduced its by-name label. Added up
# front because the precedent is identical and a build cycle is ~50 minutes.
if ! grep -q "logo_block_device:lnk_file" "$TREE/device/itel/S666LN/sepolicy/vendor/init.te" 2>/dev/null; then
  printf '\n# Step 32 labels logo through /dev/block/by-name/logo_{a,b}, which are symlinks\n# on tmpfs, so init relabels the link as well as the device. Exactly what step 29\n# had to add for tranfs after step 24.\nallow init logo_block_device:lnk_file relabelto;\n' >> "$TREE/device/itel/S666LN/sepolicy/vendor/init.te"
  echo "   init -> logo_block_device:lnk_file relabelto added (predicted from step 29)"
else
  echo "   init lnk_file relabelto already present"
fi

# --- step 33: give charger mode the service NAME its init trigger expects -----
# Second half of the offline-charging bug (step 32 is the other half). Corrected
# symptom that led here: charging works, screen shows a STATIC battery image, no
# animation, NO PERCENTAGE, no reboot.
#
# init.mt6789.rc:57 gates ALL charger-mode setup on
#     on property:init.svc.vendor.charger=running
# and no service named `vendor.charger` exists in this build -- what runs is
# `kpoc_charger` (vendor .../kpoc_charger.rc:4). So the block has never executed
# on any build of this ROM. What never ran:
#     start fuelgauged / fuelgauged_nvram  <- MTK's FUEL GAUGE, the source of battery
#                                             CAPACITY, started from NOWHERE ELSE in
#                                             the tree. No fuel gauge => no percentage.
#     mount ext4 .../nvcfg                 <- fuel-gauge calibration data
#     backlight brightness + trigger, /dev/spm perms, power/wakelock perms
#
# ⚠ THE FIRST ATTEMPT AT THIS STEP WAS WRONG, AND THE DEVICE SAID SO.
# It retargeted the TRIGGER to `init.svc.kpoc_charger=running`. That compiled and
# shipped, and produced exactly one new denial on FINAL9:
#     avc: denied { read } for property=init.svc.kpoc_charger
#       scontext=u:r:vendor_init:s0
#       tcontext=u:object_r:init_service_status_private_prop:s0
# so the trigger could never fire and the fix achieved nothing. Reason, from
# system/sepolicy/private/property_contexts:
#     :738   init.svc.          -> init_service_status_private_prop  (system-internal)
#     :229   init.svc.vendor.   -> vendor_default_prop               (vendor-readable)
# `init.svc.<name>` is SYSTEM-INTERNAL and vendor_init cannot read it; only the
# `init.svc.vendor.` prefix is vendor-visible. MTK named the service
# `vendor.charger` FOR THAT REASON -- the device tree's trigger was correct all
# along, and the missing piece is a service actually called `vendor.charger`.
#
# So: leave init.mt6789.rc PRISTINE and rename the service instead. Safe because
# the SELinux domain transition keys on the BINARY's exec label
# (/system/bin/kpoc_charger -> kpoc_charger_exec, sepolicy_vndr bsp/plat_private),
# not on the service name, so `kpoc_charger` domain still applies. Only three
# references to the name exist and all are updated here. A `vendor.`-prefixed
# name is also the Treble-correct form for a service declared in a /vendor rc.
echo "== step 33: charger-mode service name =="
MTKRC="$TREE/device/itel/S666LN/rootdir/etc/init/hw/init.mt6789.rc"
KRC="$TREE/vendor/itel/S666LN/proprietary/etc/init/kpoc_charger.rc"

# N/A on the independently-authored device tree, which never had this bug.
#
# The defect this step fixes is specific to the older tree: its init.mt6789.rc
# gated charger-mode setup on `on property:init.svc.vendor.charger=running`
# while the service that actually ran was `kpoc_charger`, so the block never
# executed and the fuel gauge never started -- hence charging with no percentage.
#
# riza220201/device_itel_S666LN uses the plain AOSP `on charger` trigger
# (init.mt6789.rc:82), which init evaluates directly in charger mode, and starts
# `fuelgauged` / `fuelgauged_nvram` inside that block (lines 112-113); both
# binaries and their rc files are in proprietary-files.txt. There is no property
# gate to get wrong, and no kpoc_charger.rc at all -- kpoc_charger is a stock
# /system/bin binary and this ROM builds system from source, so charger mode is
# AOSP's own `charger`.
#
# Skip rather than fail: absence of kpoc_charger.rc is the correct state here.
if [ ! -f "$KRC" ]; then
  echo "   N/A: no kpoc_charger.rc -- device tree uses the AOSP 'on charger' trigger"
  grep -q "^on charger" "$MTKRC" 2>/dev/null \
    && echo "   verified: init.mt6789.rc has 'on charger'" \
    || echo "   *** WARN: no 'on charger' trigger either -- check charger mode on device"
else
for f in "$MTKRC" "$KRC"; do
  [ -f "$f" ] || { echo "   *** FATAL: $f not found"; exit 1; }
done

# (a) undo the wrong first attempt if this tree still carries it
if grep -qE '^on property:init\.svc\.kpoc_charger=running$' "$MTKRC"; then
  python3 - "$MTKRC" <<'EOP'
import sys, re
p=sys.argv[1]; s=open(p).read()
s2,n = re.subn(r'(?m)^on property:init\.svc\.kpoc_charger=running$',
               'on property:init.svc.vendor.charger=running', s)
assert n==1, f"expected 1 trigger, got {n}"
open(p,'w').write(s2)
EOP
  echo "   init.mt6789.rc: reverted trigger to the stock vendor.charger form"
fi
[ "$(grep -cE '^on property:init\.svc\.vendor\.charger=running$' "$MTKRC")" = "1" ] || {
  echo "   *** FATAL: init.mt6789.rc trigger is not the expected vendor.charger form"; exit 1; }

# (b) rename the service so that property actually comes into existence
if grep -qE '^service kpoc_charger ' "$KRC"; then
  python3 - "$KRC" <<'EOP'
import sys, re
p=sys.argv[1]; s=open(p).read()
s,a = re.subn(r'(?m)^service kpoc_charger ', 'service vendor.charger ', s)
s,b = re.subn(r'(?m)^(\s*)start kpoc_charger$', r'\1start vendor.charger', s)
assert a==1 and b==1, f"expected 1 service + 1 start, got {a} and {b}"
open(p,'w').write(s)
EOP
  echo "   kpoc_charger.rc: service renamed kpoc_charger -> vendor.charger"
else
  echo "   already patched (service is vendor.charger)"
fi
[ "$(grep -cE '^service vendor\.charger ' "$KRC")" = "1" ] || {
  echo "   *** FATAL: vendor.charger service not defined"; exit 1; }
[ "$(grep -cE '^\s*start vendor\.charger$' "$KRC")" = "1" ] || {
  echo "   *** FATAL: on charger does not start vendor.charger"; exit 1; }
[ "$(grep -c 'kpoc_charger' "$KRC")" = "1" ] || {
  echo "   *** FATAL: expected exactly one kpoc_charger reference left (the binary path)"; exit 1; }
fi

# --- step 34: GApps duplicates a library the platform already installs -------
# MindTheGapps PRODUCT_COPY_FILES libjni_latinimegoogle.so into product/lib{,64},
# and LineageOS's LatinIME installs the SAME library there through a proper soong
# module (packages/inputmethods/LatinIME/java/Android.bp, cc_prebuilt_library_shared,
# prefer: true). Two owners of one path is a hard kati failure:
#
#   build/make/core/Makefile:72: error: overriding commands for target
#     out/target/product/S666LN/product/lib/libjni_latinimegoogle.so,
#     previously defined at out/soong/installs-lineage_S666LN.mk
#
# Verified byte-identical on both ABIs before dropping either side:
#   arm   442a2a8bfcb25489564bc943...   arm64  b1049983e6ac5cfc6d1c66e3...
# so nothing is lost. The soong module is kept because it is the better mechanism
# (proper module, arch-dispatched, participates in dependency resolution) and
# because the GApps side is the redundant copy.
#
# This did not surface on earlier releases: those used a different, WIP device
# tree whose package set never paired MindTheGapps with LineageOS's LatinIME.
echo "== step 34: drop GApps' duplicate libjni_latinimegoogle =="
GVMK="$TREE/vendor/gapps/arm64/arm64-vendor.mk"
if [ ! -f "$GVMK" ]; then
  echo "   N/A: no vendor/gapps (vanilla build)"
elif grep -q "libjni_latinimegoogle" "$GVMK"; then
  for abi in lib lib64; do
    P="$TREE/packages/inputmethods/LatinIME/java/assets/$([ "$abi" = lib ] && echo lib || echo lib64)/libjni_latinimegoogle.so"
    [ -f "$P" ] || { echo "   *** FATAL: platform copy missing for $abi -- do NOT drop the GApps one"; exit 1; }
  done
  sed -i "/libjni_latinimegoogle/d" "$GVMK"
  # the entry before it now ends in a dangling backslash if it was last -- normalize
  python3 - "$GVMK" <<'EOP'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r"\\\s*\n(\s*\n|\Z)", r"\n\1", s)
open(p,"w").write(s)
EOP
  echo "   removed (platform module provides both ABIs)"
else
  echo "   already patched"
fi

echo "===================================================================="
echo " apply-overlays complete"
echo "===================================================================="
