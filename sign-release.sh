#!/usr/bin/env bash
# sign-release.sh — the POST-BUILD release-signing step for crDroid 13.0 / itel RS4.
#
# WHY THIS EXISTS
#   Building with `PRODUCT_DEFAULT_DEV_CERTIFICATE` signs every APK/APEX container with our own
#   private keys, but it can NEVER stamp `release-keys`. build/make/core/config.mk says so outright:
#
#       "test-keys" marks builds signed with the old test keys ... "dev-keys" marks builds signed
#       with non-default dev keys (usually private keys from a vendor directory). Both of these tags
#       will be removed and replaced with "release-keys" when the target-files is signed in a
#       post-build step.
#
#   That post-build step is `sign_target_files_apks`, and this script is it. Skipping it is how the
#   2026-07-28 RC ended up honestly dev-keys while every build.prop CLAIMED release-keys — crDroid
#   hardcodes `BUILD_KEYS := release-keys` in sysprop.mk, so the property is not evidence. Check the
#   artifact. This script therefore ends by reading the signature off a real APK, not off a prop.
#
#   This is NOT a spoof. We really are signing with our own private release keys; `release-keys` is
#   simply what that state is called once the release flow has been run.
#
# WHAT IT DELIBERATELY DOES NOT TOUCH
#   * AVB / verified boot. No --avb_*_key flag is passed, and sign_target_files_apks only replaces an
#     AVB key when one is given for that partition (OPTIONS.avb_keys defaults to {} and
#     ReplaceAvbPartitionSigningKey() returns early). The AVB chain therefore stays byte-identical,
#     which is what keeps the device at verifiedbootstate=green under the fenrir LK. Do NOT add AVB
#     flags here without re-reading the AOSPA JOURNAL 2026-07-19 ("AVB keys deliberately UNCHANGED").
#
# PREREQUISITE THAT BITES
#   `mka bacon` DELETES the target-files intermediates when it finishes — vendor/lineage/build/tasks/
#   bacon.mk ends with `rm -rf $(call intermediates-dir-for,PACKAGING,target_files)`. So after a bacon
#   build there is nothing left to sign. Run `mka target-files-package` before this script.
#
# USAGE:  ./sign-release.sh [output-basename]

set -euo pipefail

TOP="${TOP:-$HOME/crdroid}"
DEV=S666LN
PROD=lineage_S666LN
KEYS="$TOP/vendor/crdroid-keys"
OUT="$TOP/out/target/product/$DEV"
HOSTBIN="$TOP/out/host/linux-x86/bin"
VER="${VER:-v9.20}"                      # crDroid ro.modversion
DATE="${DATE:-$(date +%Y%m%d)}"          # override to pin the artifact date across midnight
NAME="${1:-crDroidAndroid-13.0-${DATE}-${DEV}-${VER}-signed}"

red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
grn() { printf '\033[0;32m%s\033[0m\n' "$*"; }

# The releasetools shell out to `java` for signapk; use the tree's hermetic JDK.
for J in "$TOP"/prebuilts/jdk/jdk*/linux-x86/bin; do
  [ -x "$J/java" ] && export PATH="$J:$PATH" && break
done
command -v java >/dev/null || { red "ERROR: no java on PATH (needed by signapk)"; exit 1; }

# MUST run from the tree root: META/apkcerts.txt names certificates by TREE-RELATIVE path
# ("vendor/crdroid-keys/releasekey"), and sign_target_files_apks hands those straight to signapk.
# Running from anywhere else fails with
#   java.io.FileNotFoundException: vendor/crdroid-keys/releasekey.x509.pem
cd "$TOP"

# add_img_to_target_files unzips the ~3 GB target-files AND the extracted partition trees into
# $TMPDIR. Keep that off any small/RAM-backed /tmp and on the build disk.
export TMPDIR="${TMPDIR_OVERRIDE:-$TOP/tmp-release}"
mkdir -p "$TMPDIR"
avail_gb=$(df -BG --output=avail "$TMPDIR" | tail -1 | tr -dc '0-9')
[ "${avail_gb:-0}" -ge 40 ] || red "WARN: only ${avail_gb}G free on $TMPDIR — signing needs tens of GB"
grn "==> TMPDIR=$TMPDIR (${avail_gb}G free)"

[ -d "$KEYS" ] || { red "ERROR: signing keys not staged: $KEYS (apply-overlays.sh step 10)"; exit 1; }

SIGNED="$OUT/${PROD}-target_files-signed.zip"

# VERIFY_ONLY=1 re-runs ONLY the verification stage against an already-signed target-files.
# Signing takes ~25 minutes; a bug in the verification code must not cost another full run.
if [ "${VERIFY_ONLY:-0}" = "1" ]; then
  [ -f "$SIGNED" ] || { red "ERROR: VERIFY_ONLY=1 but $SIGNED does not exist"; exit 1; }
  grn "==> VERIFY_ONLY=1 — skipping [0/4]..[3/4], verifying $(basename "$SIGNED")"
else

if [ "${FROM_SIGNED:-0}" = "1" ]; then
  # Resume after a crash in the post-signing step. sign_target_files_apks does ALL of its real work
  # -- re-signing APKs, rewriting build.props, rebuilding every image -- before
  # add_img_to_target_files calls OptimizeCompressedEntries(), which merely re-stores
  # already-compressed entries uncompressed to save space. A failure there (e.g. the transient
  # "zipfile.BadZipFile: Bad magic number for central directory" seen 2026-07-28) therefore leaves a
  # COMPLETE and correct signed target-files behind, and re-running the whole 25-minute sign would
  # be pure waste. Trust it only after confirming the images really are in there.
  [ -f "$SIGNED" ] || { red "ERROR: FROM_SIGNED=1 but $SIGNED does not exist"; exit 1; }
  # A REAL integrity test, not a structural one. Counting IMAGES/ entries (or opening the file with
  # python zipfile) proves nothing: python parses only the central directory and reads members
  # lazily, so a zip whose *data* is damaged still reports as valid with the right entry count.
  # On 2026-07-28 that false confidence resumed onto a corrupt archive and only blew up two stages
  # later, inside ota_from_target_files, as
  #   file #86: bad zipfile offset (local header sig): 3638576709
  #   error: invalid compressed data to inflate META/care_map.pb
  # `unzip -t` actually inflates every member. Note its exit status is useless behind a pipe, so
  # match its success sentinel instead.
  grn "==> FROM_SIGNED=1 — integrity-testing $(basename "$SIGNED") (a few minutes)..."
  if ! unzip -t "$SIGNED" 2>&1 | grep -q "No errors detected"; then
    red "ERROR: $SIGNED is CORRUPT — refusing to resume. Re-sign from scratch (unset FROM_SIGNED)."
    exit 1
  fi
  n_img=$(python3 -c "import zipfile,sys
z = zipfile.ZipFile(sys.argv[1])
print(sum(1 for i in z.filelist if i.filename.startswith('IMAGES/')))" "$SIGNED" 2>/dev/null || echo 0)
  [ "${n_img:-0}" -ge 15 ] || {
    red "ERROR: signed target-files has only ${n_img} IMAGES/ entries — re-sign from scratch"; exit 1; }
  grn "==> FROM_SIGNED=1 — archive OK (${n_img} IMAGES/ entries); skipping [0/4] and [1/4]"
else

# Locate the target-files zip. The FILE_NAME_TAG suffix varies with BUILD_NUMBER, so glob for it
# rather than hardcoding, and take the newest.
TFDIR_BASE="$OUT/obj/PACKAGING/target_files_intermediates"
TF="$(ls -t "$TFDIR_BASE/${PROD}-target_files"*.zip 2>/dev/null | head -1 || true)"
if [ -z "$TF" ]; then
  red "ERROR: no target-files zip under $TFDIR_BASE"
  red "       \`mka bacon\` deletes it on completion (bacon.mk). Run: mka target-files-package"
  exit 1
fi
TFDIR="${TF%.zip}"
grn "==> target-files: $(basename "$TF") ($(du -h "$TF" | cut -f1))"

# --- normalise stale AVB fingerprint args -------------------------------------------------------
# The AVB footer args in META/misc_info.txt embed the build fingerprint and can go stale: they are
# expanded from a cached value with no dependency on BUILD_NUMBER, so after a BUILD_NUMBER change they
# can keep an old "eng.nobody" incremental even though every build.prop is correct. Left alone, every
# partition's AVB descriptor would advertise a fingerprint disagreeing with build.prop.
# Authoritative value = build_fingerprint.txt.
FPFILE="$OUT/build_fingerprint.txt"
if unzip -p "$TF" META/misc_info.txt 2>/dev/null | grep -q "eng\.nobody"; then
  red "==> [0/4] target-files carries stale 'eng.nobody' AVB fingerprint args"
  [ -d "$TFDIR" ] || { red "ERROR: need the extracted dir $TFDIR to repack; re-run mka target-files-package"; exit 1; }
  INCR=$(cut -d: -f2 "$FPFILE" | awk -F/ '{print $NF}')
  [ -n "$INCR" ] && [ "$INCR" != "eng.nobody" ] || { red "ERROR: build_fingerprint.txt has no usable incremental"; exit 1; }
  n=$(grep -c "eng\.nobody" "$TFDIR/META/misc_info.txt" || true)
  sed -i "s|/eng\.nobody:|/$INCR:|g" "$TFDIR/META/misc_info.txt"
  grn "    normalised $n AVB fingerprint arg(s) -> incremental '$INCR'; repacking target-files"
  # The .list file holds TREE-RELATIVE paths, so -C and -r must be relative too, from $TOP.
  REL_TFDIR="out/target/product/$DEV/obj/PACKAGING/target_files_intermediates/$(basename "$TFDIR")"
  "$HOSTBIN/soong_zip" -d -o "$REL_TFDIR.zip" -C "$REL_TFDIR" -r "$REL_TFDIR.zip.list" -sha256
else
  grn "==> [0/4] AVB fingerprint args already clean (no eng.nobody)"
fi

grn "==> [1/4] sign_target_files_apks  (tags: -test-keys -dev-keys +release-keys; AVB untouched)"
"$HOSTBIN/sign_target_files_apks" -v -d "$KEYS" "$TF" "$SIGNED"

# Catch a damaged output HERE. On 2026-07-28 this step produced a zip with corrupt member data;
# the failure only surfaced two stages later inside ota_from_target_files, which made it look like
# an OTA problem rather than a signing one. `unzip -t` inflates every member (its exit status is
# meaningless behind a pipe, hence the sentinel match).
grn "    verifying the signed archive inflates cleanly..."
if ! unzip -t "$SIGNED" 2>&1 | grep -q "No errors detected"; then
  red "ERROR: sign_target_files_apks produced a CORRUPT archive: $SIGNED"
  red "       Clear \$TMPDIR and re-run; do NOT resume with FROM_SIGNED."
  exit 1
fi

# Flags mirror what `bacon` itself uses (build/make/core/Makefile:6247 build-ota-package-target plus
# vendor/lineage/build/tasks/bacon.mk): --backup=true enables LineageOS' addon.d backuptool, and
# TARGET_EXCLUDE_BACKUPTOOL is not set for this device. The OTA zip's own signing key is read from
# the signed target-files' misc_info (default_system_dev_certificate), so no -k is needed here.
fi   # end of [0/4]+[1/4], skipped by FROM_SIGNED

grn "==> [2/4] ota_from_target_files -> ${NAME}.zip"
"$HOSTBIN/ota_from_target_files" --verbose --backup=true --path out/host/linux-x86 \
  "$SIGNED" "$OUT/${NAME}.zip"

# Fastboot fallback. Worth having: a recovery that silently declines to write `boot` is exactly how
# the 2026-07-28 "reflex is missing" scare happened — flashing images directly bypasses that class of
# bug. build_super_image is deliberately NOT run (the raw-super install path was dropped).
grn "==> [3/4] img_from_target_files -> ${NAME}-images.zip (fastboot path)"
"$HOSTBIN/img_from_target_files" "$SIGNED" "$OUT/${NAME}-images.zip" || \
  red "WARN: img_from_target_files failed — the OTA zip is still the primary artifact"

fi   # end of the signing stages skipped by VERIFY_ONLY

grn "==> [4/4] verify"
TMPV="$(mktemp -d)"; trap 'rm -rf "$TMPV"' EXIT
unzip -o -q "$SIGNED" 'SYSTEM/build.prop' 'VENDOR/build.prop' 'PRODUCT/etc/build.prop' \
  'SYSTEM_EXT/etc/build.prop' 'ODM/etc/build.prop' -d "$TMPV" 2>/dev/null || true
bad=0
while IFS= read -r bp; do
  tags=$(grep -h '^ro\..*\.build\.tags=' "$bp" 2>/dev/null | head -1)
  fp=$(grep -h '^ro\..*\.build\.fingerprint=' "$bp" 2>/dev/null | head -1)
  printf '   %-14s %s\n' "$(basename "$(dirname "$bp")")" "${tags:-<no tags line>}"
  case "$tags" in *release-keys*) ;; *) red "     ^ NOT release-keys"; bad=1 ;; esac
  case "$fp" in *release-keys*) ;; *) red "     ^ fingerprint not release-keys: $fp"; bad=1 ;; esac
done < <(find "$TMPV" -name build.prop)
if grep -qra 'dev-keys' "$TMPV" 2>/dev/null; then
  red "   WARN: a 'dev-keys' string is still present in a build.prop"; bad=1
fi

# AVB descriptor props must agree with build.prop (no stale eng.nobody, no dev-keys).
unzip -o -q "$SIGNED" 'META/misc_info.txt' -d "$TMPV" 2>/dev/null || true
if [ -f "$TMPV/META/misc_info.txt" ]; then
  for pat in 'eng\.nobody' 'dev-keys'; do
    if grep -qa "$pat" "$TMPV/META/misc_info.txt"; then
      red "   WARN: AVB args still contain '$pat'"; bad=1
    fi
  done
fi

# THE actual proof. Every earlier "verified release-keys" claim read a property that crDroid
# hardcodes; this reads the certificate off a signed APK inside the signed target-files.
# apksigner prints "Signer #1 certificate DN: ...". keytool is the one that prints "Subject:" --
# grepping for the wrong label silently yields <unreadable> and fails a build that was actually fine.
APKSIGNER="$(command -v apksigner || echo "$HOSTBIN/apksigner")"
TESTAPK="$(unzip -Z1 "$SIGNED" 'SYSTEM/priv-app/*/*.apk' 2>/dev/null | head -1 || true)"
if [ -n "$TESTAPK" ] && [ -x "$APKSIGNER" ]; then
  unzip -o -q "$SIGNED" "$TESTAPK" -d "$TMPV"
  dn="$("$APKSIGNER" verify --print-certs "$TMPV/$TESTAPK" 2>/dev/null | grep -m1 'certificate DN:' || true)"
  printf '   %-14s %s\n' "platform apk" "$(basename "$TESTAPK")"
  printf '   %-14s %s\n' "signer DN" "${dn#*certificate DN: }"
  case "$dn" in
    "")            red "   ^ could not read signer; inspect manually"; bad=1 ;;
    *O=Android,*)  red "   ^ STILL AOSP TEST KEY — do not ship"; bad=1 ;;
    *crDroid*)     grn "   OK: signed with our own release key" ;;
    *)             red "   ^ unexpected signer; inspect manually"; bad=1 ;;
  esac
else
  red "   WARN: could not run apksigner ($APKSIGNER) — signer NOT verified"
fi

# GApps must KEEP its Google signature (android_app_import presigned:true). If our keys ever landed
# on GmsCore, Play Services would be rejected by Google's servers and could never self-update --
# the exact class of breakage that made the flashed NikGapps unusable.
GAPPSAPK="PRODUCT/priv-app/GmsCore/GmsCore.apk"
if unzip -Z1 "$SIGNED" "$GAPPSAPK" >/dev/null 2>&1 && [ -x "$APKSIGNER" ]; then
  unzip -o -q "$SIGNED" "$GAPPSAPK" -d "$TMPV"
  gdn="$("$APKSIGNER" verify --print-certs "$TMPV/$GAPPSAPK" 2>/dev/null | grep -m1 'certificate DN:' || true)"
  case "$gdn" in
    *"O=Google Inc."*) grn "   OK: GmsCore still Google-signed (presigned preserved)" ;;
    *) red "   ^ GmsCore signer is NOT Google: ${gdn:-<unreadable>}"; bad=1 ;;
  esac
fi

sha256sum "$OUT/${NAME}.zip" | tee "$OUT/${NAME}.zip.sha256"
[ "$bad" -eq 0 ] && grn "==> RELEASE SIGNED OK: $OUT/${NAME}.zip" || red "==> VERIFY FAILED — do not ship"
exit "$bad"
