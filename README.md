# itel RS4 (S666LN) → crDroid 13.0 (Android 13)

Port recipe for building **crDroid 13.0** (Android 13) for the **itel RS4** (`S666LN`, MediaTek
**MT6789 / Helio G99**), with the **Riza kernel** (`5.10.260-Riza-vanilla`, reflex + BORE + ntsync)
baked into `boot.img`, on the device's **own honest identity** — no Pixel spoofing anywhere.

This repo is the **recipe**, not the Android source tree — a local manifest plus idempotent scripts
that graft the MT6789 device stack onto crDroid and fix every breakage from `lunch` through release
signing. `repo sync` + `apply-overlays.sh` + `sign-release.sh` reproduces the released zip — **with
one caveat: the device tree itself is no longer hosted publicly** and must be obtained separately
(see [Credits](#credits) and the note in `local_manifests/S666LN.xml`). Everything else syncs.

## What this build is

- **Security patch `2026-02-01`.** crDroid 13.0 is abandoned upstream (last commit 2024-09, SPL
  `2024-09-05`), but its manifest tracks `refs/heads/lineage-20.0`, and LineageOS still backports
  monthly ASBs onto LOS-20. Merging crDroid's ~6 frozen forks forward onto live lineage-20.0 buys
  **~17 months** of security patches.
- **Zero spoofing.** crDroid's `PixelPropsUtils` reports a Pixel 9 to GMS and a Pixel 5a to the Play
  Store — an Android 14/15 identity on an Android 13 system — and *throws* from
  `onEngineGetCertificateChain()` on every DroidGuard/Finsky attestation request. That is why Play
  Integrity returned an **empty verdict list**. This device has a genuine Trustonic keybox, so the
  "integrity helper" was the only thing breaking integrity. It is disabled at compile time here.
- **e-KYC works** (ShopeePay / BRImo / Shopee) on the device's real itel identity. On Android 13
  `itel S666LN + 13` is a device+OS pair that genuinely exists, which is exactly what the e-KYC
  servers check — so nothing has to be invented.
- **Genuinely release-key signed**, not dev-keys wearing a `release-keys` label.
- **USB debugging off by default**, GApps built in, SELinux enforcing.

## Layout

| Path | What |
|---|---|
| `local_manifests/S666LN.xml` | device stack (device/vendor/kernel + LineageOS MTK hardware & sepolicy + swaraloka-lab transsion), plus crDroid dead-branch manifest-drift fixes |
| `apply-overlays.sh` | **33 idempotent steps** — the single place every port fixup lives. Re-run after any `repo sync`. (Step 30 is a deliberate no-op that *reverts* an abandoned experiment; see its comment block.) |
| `crdroid-build-rc.sh` | builds `target-files-package` (not `bacon` — see below) with the stock incremental pinned |
| `sign-release.sh` | release-signs the target-files and builds the OTA. `VERIFY_ONLY=1` re-checks an existing one; `FROM_SIGNED=1` resumes after signing |
| `crdroid-tf.sh` | bare target-files helper |
| `gamespace/` | sources for the GameSpace bypass-charging tile (staged by `apply-overlays.sh` step 19) |

**Not in this repo:**

- 🔴 **`s666ln-fenrir-signed.bin`** — the **mandatory** signed "fenrir" LK. It is what makes the
  bootloader report green/locked verified boot, it is **not** part of any ROM OTA, and it persists
  across ROM flashes. A device that never had it will not reproduce this build's boot state, and
  integrity will not behave. Proprietary signed bootloader, **not redistributed here** — obtain it
  from the device community (**@itelRS4Updates** on Telegram).
- **Signing keys** (`keys-priv/`) — generate your own; they sign platform-privileged code.
- **The Riza kernel prebuilt** (`kernel-stage/Image.gz`) — published separately at
  [`riza220201/itel-rs4-kernel`](https://github.com/riza220201/itel-rs4-kernel).
- **Proprietary MediaTek blobs** (`blobs32/`, `blobs-camera-raw/`) and the stock firmware zip.

## Reproduce

```sh
# 1. Source tree (~105 GB synced; the build needs ~250 GB and 32 GB+ RAM)
mkdir -p ~/crdroid && cd ~/crdroid
repo init -u https://github.com/crdroidandroid/android -b 13.0 --depth=1 --no-repo-verify
cp <this-repo>/local_manifests/S666LN.xml .repo/local_manifests/
repo sync -c --no-tags --force-sync -j8

# 1b. The device tree is NOT in the manifest (no public host — see Credits).
#     Place it at device/itel/S666LN yourself before continuing. The kernel and
#     vendor trees DO sync normally.

# 2. Apply every overlay/fixup (idempotent; re-run after any future sync)
bash <this-repo>/apply-overlays.sh ~/crdroid

# 3. Build the target-files, then release-sign it into the OTA
bash <this-repo>/crdroid-build-rc.sh      # ~11 min warm ccache
bash <this-repo>/sign-release.sh          # ~25 min -> ...-signed.zip
```

Host prerequisite beyond a stock Ubuntu 22.04 AOSP setup: **`libncurses5 libtinfo5`**. Android 13's
RenderScript ships an old prebuilt clang linked against `libncurses.so.5`, which no longer exists on
22.04, and it fails partway into the compile.

### Why `target-files-package` and not `bacon`

`vendor/lineage/build/tasks/bacon.mk` ends by deleting the target-files it just built, and its OTA is
unsigned dev-keys. Build the target-files and let `sign-release.sh` produce the OTA from the *signed*
one.

### crDroid 13 is unsignable out of the box

crDroid commit `29535c284` cut `BUILD_DESC` in `build/make/core/sysprop.mk` down to `$(BUILD_ID)`, so
`ro.build.description` has a single token. `sign_target_files_apks.py` asserts its last token ends in
`-keys` and dies with a bare `AssertionError`. `apply-overlays.sh` step 14 restores it. **Any**
crDroid 13 device tree hits this the moment it tries to release-sign.

## Flash

1. 🔴 **fenrir LK first**, if the device has never had it (see above).
2. 🔴 **Format data.** The signing keys differ from stock, so existing `/data` cannot be decrypted.
3. Use a recovery that actually **writes the boot partition** — stock or *unpatched* OrangeFox. A
   patched OrangeFox silently skips `boot`, which leaves the previous ROM's kernel running while
   every `build.prop` claims otherwise.
4. Sideload the signed zip, reboot.

GApps are **built in** — do not flash a GApps package on top.

## Notes

- **Play Integrity** sits at **BASIC + DEVICE**, and that is the expected state. STRONG was seen once
  early on but is not reachable from the ROM side — identity, both SPLs, fenrir, AVB, signing keys,
  kernel, root, GMS version, device reputation and the Trustonic keybox were each eliminated with
  evidence. **e-KYC does not depend on it and passes at DEVICE** (the two checks read different
  inputs: attestation vs. a five-field device identity).
- **Camera RAW**: the patched MTK HAL blobs make both cameras advertise `RAW` + `MANUAL_SENSOR`, and
  a Camera2 app captures real 4096×3072 GRBG DNGs. The bundled Aperture cannot show a RAW toggle —
  lineage-20's Aperture has no DNG support in its source at all, and RAW only reached Aperture in
  lineage-23.0 via a CameraX API that its `CameraController` architecture cannot access. Use a
  third-party Camera2 app for RAW.
- **Bypass charging** is exposed as a tile in crDroid's GameSpace game bar (not a QS tile). It stops
  charging the cell and lets the adapter carry the system load during long sessions. It never
  persists: the node resets on reboot, so an interrupted session can't leave a phone that won't
  charge.
- **Load average ~12 is this device's floor**, on stock too — 12 permanently-D-state MediaTek kernel
  threads (`wdtk-0..7`, `hang_detect`, `tee_irq_bh`, `ccci_poll1`, `resource_monito`) with the CPU
  ~97% idle. Do not use loadavg as a health metric on this SoC.

## Credits

- **[KimelaZX](https://github.com/KimelaZX)** — the S666LN device, vendor and kernel trees this port
  is built on. The [kernel](https://github.com/KimelaZX/device_itel_S666LN-kernel) and
  [vendor](https://github.com/KimelaZX/vendor_itel_S666LN) trees are still published there.
  **The device tree is not currently hosted publicly anywhere** — see the note in
  `local_manifests/S666LN.xml`. Obtain it from the device community
  (**@itelRS4Updates** on Telegram); this recipe supplies only the fixes applied on top of it.
- **crDroid Android**, **LineageOS**, **swaraloka-lab** (Transsion hardware), **MindTheGapps**
- **chaldeaprjkt** — GameSpace · **firelzrd** — BORE · **Masahito Suzuki** — reflex governor
