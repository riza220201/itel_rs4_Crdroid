#!/usr/bin/env bash
# sign-release.sh -- the POST-BUILD release-signing step for the ROM in rom.conf (crDroid 16) / itel RS4 (S666LN);
# the AICP recipe's signer, with the product name read from rom.conf.
# Ported from the crDroid recipe's sign-release.sh; its traps are kept.
#
# WHY: an in-tree build can never stamp `release-keys` (build/make/core/config.mk: "test-keys" /
# "dev-keys" are replaced with "release-keys" only when the target-files is signed in a post-build
# step). That step is sign_target_files_apks, and this script runs it. The build itself stays on the
# AOSP test keys -- no tree change at all -- and `-d $KEYS` maps every test-key certificate onto ours:
# exactly the seven BuildKeyMap() knows (testkey/devkey -> releasekey, platform, shared, media,
# networkstack, sdk_sandbox, bluetooth).
# The proof at the end reads the certificate off a signed APK, never a property.
#
# NOT TOUCHED: AVB. No --avb_*_key flag is passed, so the AVB chain stays byte-identical, which is
# what keeps verifiedbootstate=green under the patched LK.
#
# KEYS live OUTSIDE the tree and outside every repo: $KEYS (default ~/rs4-release-keys, mode 700,
# files 600). They are the operator's own ROM-neutral set, O=CN=Riza-S666LN (made 2026-11-14 with AOSP
# make_key; the crDroid-era set said crDroid-S666LN). On the rental server they are wiped before the
# rental ends. The recipe's .gitignore firewalls keys-priv/, *.pk8, *.x509.pem.
#
# USAGE: TOP=<tree> ./sign-release.sh [output-basename]
#   VERIFY_ONLY=1  re-run only the verification against an existing signed target-files
set -euo pipefail

TOP="${TOP:?set TOP to the ROM tree}"
DEV=S666LN
. "$(cd "$(dirname "$0")" && pwd)/rom.conf"
PROD="$ROM_PRODUCT"
KEYS="${KEYS:-$HOME/rs4-release-keys}"
OUT="$TOP/out/target/product/$DEV"
HOSTBIN="$TOP/out/host/linux-x86/bin"
DATE="${DATE:-$(date -u +%Y%m%d)}"
NAME="${1:-${PROD}-${DATE}-signed}"
EXPECT_DN="${EXPECT_DN:-Riza-S666LN}"       # our release key's O= / CN=

red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
grn() { printf '\033[0;32m%s\033[0m\n' "$*"; }

for J in "$TOP"/prebuilts/jdk/jdk*/linux-x86/bin; do
  [ -x "$J/java" ] && export PATH="$J:$PATH" && break
done
command -v java >/dev/null || { red "ERROR: no java on PATH (needed by signapk)"; exit 1; }
cd "$TOP"     # apkcerts.txt names certificates by tree-relative path

export TMPDIR="${TMPDIR_OVERRIDE:-$TOP/tmp-release/sign}"
mkdir -p "$TMPDIR"
avail_gb=$(df -BG --output=avail "$TMPDIR" | tail -1 | tr -dc '0-9')
[ "${avail_gb:-0}" -ge 40 ] || red "WARN: only ${avail_gb}G free on $TMPDIR -- signing needs tens of GB"

for k in releasekey platform shared media networkstack sdk_sandbox bluetooth; do
  [ -f "$KEYS/$k.pk8" ] && [ -f "$KEYS/$k.x509.pem" ] || { red "ERROR: $KEYS/$k.{pk8,x509.pem} missing"; exit 1; }
done
perm=$(stat -c %a "$KEYS"); [ "$perm" = 700 ] || { red "ERROR: $KEYS is mode $perm, must be 700"; exit 1; }
grn "==> keys: $KEYS (mode 700, $(ls "$KEYS"/*.pk8 | wc -l) private keys)"

SIGNED="$OUT/${PROD}-target_files-signed.zip"

if [ "${VERIFY_ONLY:-0}" != "1" ]; then
  TF="$(ls -t "$OUT/obj/PACKAGING/target_files_intermediates/${PROD}-target_files"*.zip 2>/dev/null | head -1 || true)"
  [ -n "$TF" ] || { red "ERROR: no target-files zip (build GOAL must produce it; bacon keeps it)"; exit 1; }
  grn "==> target-files: $(basename "$TF") ($(du -h "$TF" | cut -f1))"

  grn "==> [1/3] sign_target_files_apks (-test-keys -dev-keys +release-keys; AVB untouched)"
  "$HOSTBIN/sign_target_files_apks" -v -d "$KEYS" "$TF" "$SIGNED"
  # `unzip -t` inflates every member; its status is useless behind a pipe, so match the sentinel.
  grn "    verifying the signed archive inflates cleanly..."
  unzip -t "$SIGNED" 2>&1 | grep -q "No errors detected" \
    || { red "ERROR: sign_target_files_apks produced a CORRUPT archive: $SIGNED"; exit 1; }

  grn "==> [2/3] ota_from_target_files -> ${NAME}.zip"
  # -k is REQUIRED here: without it ota_from_target_files signs the package with misc_info's
  # default_system_dev_certificate, which on a test-keys build is build/make/target/product/security/testkey
  # (build 15 shipped that way) -- while the signed image's otacerts already expect OUR releasekey.
  "$HOSTBIN/ota_from_target_files" --verbose --backup=true --path out/host/linux-x86 \
    -k "$KEYS/releasekey" "$SIGNED" "$OUT/${NAME}.zip"
fi

grn "==> [3/3] verify"
TMPV="$(mktemp -d)"; trap 'rm -rf "$TMPV"' EXIT
unzip -o -q "$SIGNED" 'SYSTEM/build.prop' 'VENDOR/build.prop' 'PRODUCT/etc/build.prop' \
  'SYSTEM_EXT/etc/build.prop' 'ODM/etc/build.prop' -d "$TMPV" 2>/dev/null || true
bad=0
while IFS= read -r bp; do
  tags=$(grep -h '^ro\..*build\.tags=' "$bp" 2>/dev/null | head -1)
  fp=$(grep -h '^ro\..*build\.fingerprint=' "$bp" 2>/dev/null | head -1)
  printf '   %-14s %s\n' "$(basename "$(dirname "$bp")")" "${tags:-<no tags line>}"
  case "$tags" in *release-keys*) ;; *) red "     ^ NOT release-keys"; bad=1 ;; esac
  case "$fp" in ""|*release-keys*) ;; *) red "     ^ fingerprint not release-keys: $fp"; bad=1 ;; esac
done < <(find "$TMPV" -name build.prop)
# Only PROPERTY lines count: post_process_props comments out an optional (?=) default that an
# explicit value overrode (e.g. "#ro.build.description?=... test-keys" under a device's own
# description), and sign_target_files_apks rightly leaves comments alone (build 18).
# `|| true`: under set -e + pipefail, grep's "no match" (exit 1) in the CLEAN case would end the script.
leaks=$(grep -rah -E 'test-keys|dev-keys' "$TMPV" 2>/dev/null | grep -v -E '^[[:space:]]*#' || true)
[ -n "$leaks" ] && { red "   ^ a test-keys/dev-keys string is still in a build.prop property:"; printf '%s\n' "$leaks" | head -5 | sed 's/^/     /'; bad=1; }
grep -h -E '^ro\.build\.type=|^ro\.debuggable=' "$TMPV"/SYSTEM/build.prop 2>/dev/null | sed 's/^/   /'
grep -q '^ro.build.type=user$' "$TMPV/SYSTEM/build.prop" 2>/dev/null || { red "   ^ not a user build"; bad=1; }

APKSIGNER="$(command -v apksigner || echo "$HOSTBIN/apksigner")"

# The OTA package's own signature (whole-file signapk -w, checked by any verifying recovery) must be
# ours too. ota_from_target_files embeds the signing certificate as META-INF/com/android/otacert.
if [ -f "$OUT/${NAME}.zip" ]; then
  odn="$(unzip -p "$OUT/${NAME}.zip" META-INF/com/android/otacert 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
  printf '   %-14s %s\n' "ota signer" "${odn:-<no otacert>}"
  case "$odn" in *"$EXPECT_DN"*) ;; *) red "   ^ OTA package not signed with our release key"; bad=1 ;; esac
fi

# THE proof: the certificate on a signed platform APK, not a property.
# apksigner prints "Signer #1 certificate DN:"; keytool's label is different -- do not mix them.
for TESTAPK in 'SYSTEM/priv-app/SettingsProvider/SettingsProvider.apk' "$(unzip -Z1 "$SIGNED" 'SYSTEM/priv-app/*/*.apk' 2>/dev/null | head -1)"; do
  unzip -Z1 "$SIGNED" "$TESTAPK" >/dev/null 2>&1 || continue
  unzip -o -q "$SIGNED" "$TESTAPK" -d "$TMPV"
  dn="$("$APKSIGNER" verify --print-certs "$TMPV/$TESTAPK" 2>/dev/null | grep -m1 'certificate DN:' || true)"
  printf '   %-14s %s\n' "apk" "$TESTAPK"; printf '   %-14s %s\n' "signer DN" "${dn#*certificate DN: }"
  case "$dn" in
    "")              red "   ^ could not read signer"; bad=1 ;;
    *O=Android,*)    red "   ^ STILL AOSP TEST KEY -- do not ship"; bad=1 ;;
    *"$EXPECT_DN"*)  grn "   OK: signed with our own release key" ;;
    *)               red "   ^ unexpected signer"; bad=1 ;;
  esac
  break
done

[ -f "$OUT/${NAME}.zip" ] && sha256sum "$OUT/${NAME}.zip" | tee "$OUT/${NAME}.zip.sha256"
[ "$bad" -eq 0 ] && grn "==> RELEASE SIGNED OK: $OUT/${NAME}.zip" || red "==> VERIFY FAILED -- do not ship"
exit "$bad"
