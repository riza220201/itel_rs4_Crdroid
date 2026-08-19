#!/bin/bash
#
# apply-overlays-v2.sh <TREE_PATH>
#
# ROM CONFIGURATION ONLY. Idempotent crDroid 13.0 / itel RS4 (S666LN) recipe.
# Re-run after any `repo sync`. Each step is guarded so re-running is safe.
#
# WHY THIS FILE EXISTS (BLUEPRINT.md §10)
# ---------------------------------------
# apply-overlays.sh did two unrelated jobs: it repaired defects in a device tree
# we no longer use, and it configured the ROM. Now that device_itel_S666LN is
# ours, the first job is finished -- the tree implements those fixes natively --
# and only the second belongs in a recipe. 22 of the original 35 steps are gone.
#
# STEP NUMBERS ARE DELIBERATELY NOT RENUMBERED. Four project journals reference
# steps by number; renumbering would silently invalidate that archaeology. The
# gaps below are the record of what was absorbed into the tree.
#
# Removed, and why:
#   step 2   native   tree ships no vendorsetup.sh at all
#   step 3   dropped  RAW blobs: crDroid 13's Aperture has no RAW UI (crDroid JOURNAL:522), and the libs are Millennium-sourced
#   step 4   native   configs/vintf/manifest.xml (thermal @1.0/@2.0 is in stock)
#   step 5   native   device.mk ships vndservicemanager
#   step 6   native   rootdir/etc/init/hw/init.mt6789.rc
#   step 7   native   sepolicy/vendor/pnpmgr.te and friends
#   step 9   native   sepolicy/vendor/*.te (was re-appending a DUPLICATE dontaudit)
#   step 11  native   sepolicy/vendor/ntsync_app.te + rootdir/etc/ueventd.mt6789.rc
#   step 13  native   the tree never had the forced-ADB block to remove
#   step 18  native   lineage_S666LN.mk PRODUCT_SYSTEM_NAME/DEVICE + BoardConfig VENDOR_SECURITY_PATCH
#   step 20  moved    ro.product.marketname now in configs/properties/system.prop
#   step 21  native   sepolicy/vendor/trustonic_kmsetkey_ca.te + file_contexts
#   step 22  native   sepolicy/vendor/*.te
#   step 23  native   sepolicy/vendor/*.te
#   step 24  native   sepolicy/vendor/file_contexts labels tranfs BY-NAME
#   step 25  native   sepolicy/vendor/*.te
#   step 26  native   sepolicy/vendor/*.te
#   step 27  native   sepolicy/vendor/mtk_hal_camera.te
#   step 29  native   sepolicy/vendor/*.te
#   step 30  void     WITHDRAWN long ago; body was already a no-op (BLUEPRINT §13)
#   step 32  native   sepolicy/vendor/file_contexts has logo_a/logo_b
#   step 33  harmful  tree uses stock's 'on charger'; the rename would BREAK it (BLUEPRINT §7)
#
# 'native'  = device_itel_S666LN does it; re-running would be a no-op at best.
# 'moved'   = it was a device fact in the wrong repo; the tree owns it now.
# 'void'    = withdrawn feature, body was already inert.
# 'harmful' = applying it to THIS tree would reintroduce a bug.
# 'dropped' = feature deliberately not shipped.
#
# The removed bodies are not lost: `git log -p -- apply-overlays.sh` in this
# repo carries every one of them, with its full diagnosis.
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

# 🔴 WRITE ONLY IF THE CONTENT ACTUALLY CHANGED.
# ninja keys on mtime, not content, and this file is in frameworks/base -- so an
# unconditional rewrite with identical bytes invalidates the whole metalava API
# stub chain (system-api-stubs-docs-non-updatable and friends), which is 30+
# minutes on the local box. This step is idempotent in CONTENT and was not
# idempotent in MTIME, so re-running the recipe -- which the header explicitly
# invites, "Re-run after any repo sync" -- silently cost a stub rebuild every
# time. Measured 2026-08-18 after ~8 runs in one session.
orig = io.open(p, encoding="utf-8").read()
if s != orig:
    io.open(p, "w", encoding="utf-8").write(s)
    print("   PixelPropsUtils: SPOOF_ENABLED=false; %d gate(s) retired onto it" % (a + b))
else:
    print("   PixelPropsUtils: already patched, file untouched (mtime preserved)")
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

# --------------------------------------------------------------------------
# hardware/mediatek/bootctrl builds android.hardware.boot@1.2-mtkimpl for both
# ABIs. The 32-bit variant cannot compile on this tree:
# vendor/lineage/build/soong's generated_kernel_includes runs headers_install
# once, for ARCH=$(KERNEL_ARCH) = arm64, then exports the result to every ABI
# through one cc_library_headers. A 32-bit compile therefore reads arm64's
# asm/sigcontext.h and dies on
#     error: unknown type name '__uint128_t'   (__uint128_t vregs[32];)
#
# Only the 64-bit impl is ever loaded -- android.hardware.boot@1.2-service is a
# 64-bit process and dlopen's it out of /vendor/lib64/hw -- so restricting the
# module to the primary arch loses nothing.
#
# This is patched here rather than in the device tree because it is a defect in
# a repo the device tree does not own, and it cannot be worked around from the
# device side: a vendor/itel/S666LN prebuilt cannot displace it, because soong's
# prefer: only pairs prebuilt with source inside one namespace and
# hardware/mediatek is a separate imported namespace. See device.mk.
#
# DURABLE FIX: upstream compile_multilib to LineageOS, or carry a fork of
# android_hardware_mediatek. Until then this step is mandatory -- without it the
# build fails at ~16%.
echo "== step 35: restrict android.hardware.boot@1.2-mtkimpl to 64-bit =="
BCBP="$TREE/hardware/mediatek/bootctrl/Android.bp"
if [ ! -f "$BCBP" ]; then
  echo "   N/A: hardware/mediatek/bootctrl not synced"
elif grep -q 'compile_multilib: "first"' "$BCBP"; then
  echo "   already patched"
else
  sed -i 's|^    stem: "android.hardware.boot@1.0-impl-1.2-mtkimpl",|&\n    // 32-bit cannot build: generated_kernel_headers are arm64-only (apply-overlays step 35)\n    compile_multilib: "first",|' "$BCBP"
  grep -q 'compile_multilib: "first"' "$BCBP" || { echo "   *** FATAL: patch did not apply"; exit 1; }
  echo "   patched"
fi

# --- step 36: stop hardware/mediatek defining the AIDL power impl -----------
# Same class as step 35: a defect we cannot work around from the device side,
# in a repo the device tree does not own (hardware/mediatek is LineageOS's).
#
# hardware/mediatek/aidl/power-mediatek builds
# android.hardware.power-service-mediatek. This device must use STOCK's copy of
# that library instead -- itel's prebuilt mtkpower@1.0-service is compiled
# against stock's libpowerhal, and pairing it with the source build aborts at
# runtime inside libpowerhal_Init(1) (measured on hardware 2026-08-11; the HIDL
# half registers, the AIDL thread dies in Power::Power()).
#
# The device tree therefore ships stock's .so through PRODUCT_COPY_FILES. That
# is not enough on its own: base_rules.mk:533 creates an install rule for the
# module's output as soon as the module is DEFINED, whether or not anything
# requests it, so both rules target the same path and kati refuses:
#
#   Makefile:72: error: overriding commands for target
#     out/target/product/S666LN/vendor/lib64/android.hardware.power-service-mediatek.so
#
# Scoped to this device rather than deleted outright, so the same
# hardware/mediatek checkout still builds every other MTK target normally.
#
# DURABLE FIX: same as step 35 -- upstream a guard, or carry a fork of
# android_hardware_mediatek.
echo "== step 36: exclude hardware/mediatek's AIDL power impl for S666LN =="
PWRMK="$TREE/hardware/mediatek/aidl/power-mediatek/Android.mk"
if [ ! -f "$PWRMK" ]; then
  echo "   N/A: hardware/mediatek/aidl/power-mediatek not synced"
elif head -1 "$PWRMK" | grep -q 'S666LN'; then
  echo "   already patched"
else
  sed -i '1i ifeq (,$(filter S666LN,$(TARGET_DEVICE)))' "$PWRMK"
  printf 'endif\n' >> "$PWRMK"
  head -1 "$PWRMK" | grep -q 'S666LN' || { echo "   *** FATAL: guard not applied"; exit 1; }
  tail -1 "$PWRMK" | grep -q '^endif$' || { echo "   *** FATAL: endif not appended"; exit 1; }
  echo "   patched (module now defined only for non-S666LN targets)"
fi


echo "===================================================================="
echo " apply-overlays-v2 complete  (ROM configuration only)"
echo "===================================================================="
