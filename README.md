# itel RS4 (S666LN) → crDroid 16.0 (Android 16) — branch `16.0`

Build **recipe** for **crDroid 16.0** (`crdroidandroid/android`, branch `16.0`, LineageOS 23.2 base, `BP4A.251205.006`)
on the **itel RS4** (`S666LN`, MediaTek **MT6789 / Helio G99**). This branch is a new recipe for the Android 16 device
tree; `main` keeps the earlier crDroid recipe. The same design as
[`itel_rs4_AICP`](https://github.com/riza220201/itel_rs4_AICP), [`itel_rs4_Axion`](https://github.com/riza220201/itel_rs4_Axion)
and [`itel_rs4_LineageOS`](https://github.com/riza220201/itel_rs4_LineageOS): a local manifest plus idempotent scripts,
not the Android source tree. Everything ROM-specific is in **`rom.conf`**.

## The device stack (branch `lineage-23.2` in each)

| repo | role |
|---|---|
| `device_itel_S666LN` | device glue, sepolicy, overlays; the `lineage_S666LN` product |
| `device_itel_S666LN-kernel` | dtb, dtbo, 198 + 206 modules, **`prebuilt/` = the published Neutron-built vanilla kernel** (imported, committed) |
| `vendor_itel_S666LN` | blobs from stock rev 28 via 23.2's extract-utils |

The kernel is never compiled in the ROM. The build presents the Pixel 10 identity (`S666LN_IDENTITY=pixel10`, set
in `rom.conf`): itel never shipped Android 16, and e-KYC rejects a device+OS pair that does not exist.

## Layout

| path | what |
|---|---|
| `rom.conf` | the ROM: manifest, product + release, build goal, who owns `build/soong`, artifact names, identity |
| `local_manifests/S666LN.xml` | the tree's `.repo/local_manifests/S666LN.xml` (the build refuses to run if they differ) |
| `sync.sh` | flock'd, shallow, stall-timeout `repo sync` |
| `tools/verify-sync.sh` | read-only: worktrees, shallowness, LFS payloads, `tmp_pack_*`, the ROM owns build/soong, `repo status` |
| `apply-overlays.sh` | **ROM configuration only**, numbered idempotent steps (1: imported kernel; 3–6: framework fixes for this SoC) |
| `rom-build.sh` | preflight (RAM, out-dir disk, sync lock, LFS, manifest, device tree clean + on `lineage-23.2`, test-key dev certificate) → `lunch lineage_S666LN-bp4a-<variant>` → `m otapackage` |
| `build-and-sign.sh` | the detached driver: verify-sync → apply-overlays → build → adb-mode gate → release signing → VERDICT |
| `sign-release.sh` | `sign_target_files_apks` with your own keys, then `ota_from_target_files -k`, then proof the signer is yours |

The goal is **`otapackage`, not `bacon`**: crDroid's `bacon` deletes the target-files that release signing needs.
The local manifest also moves ten AOSP projects to LineageOS's forks (November 2026 security backports), because
crDroid 16.0's manifest lags its LineageOS base by one merge and the LineageOS projects it already pulls depend on
them (CellBroadcastReceiver failed to compile without them). Drop that block once crDroid merges them itself.
crDroid 16's Game Space has bypass charging built in through LineageOS Health charging control, so step 7 (AICP's
Game Space tile) does not apply here. microG is flashed on top separately.

## Reproduce

```sh
git clone -b 16.0 https://github.com/riza220201/itel_rs4_Crdroid.git ~/itel_rs4_Crdroid
mkdir -p ~/crdroid && cd ~/crdroid
repo init -u https://github.com/crdroidandroid/android.git -b 16.0 --git-lfs --depth=1 --no-clone-bundle
mkdir -p .repo/local_manifests && cp ~/itel_rs4_Crdroid/local_manifests/S666LN.xml .repo/local_manifests/
TOP=~/crdroid ~/itel_rs4_Crdroid/sync.sh && TOP=~/crdroid ~/itel_rs4_Crdroid/tools/verify-sync.sh
# the build refuses a device tree that is not on its branch (detached HEAD after a sync)
repo start lineage-23.2 device/itel/S666LN device/itel/S666LN-kernel vendor/itel/S666LN

TOP=~/crdroid OUT_TARGET=~/crdroid/out VARIANT=user SIGN=1 \
  setsid nohup bash ~/itel_rs4_Crdroid/build-and-sign.sh > /dev/null 2>&1 < /dev/null &
```

The JamesDSP control app is not in git: the device tree's `tools/build-jamesdsp.sh` builds it into
`device/itel/S666LN/prebuilts/JamesDSP/`; without it AudioFX ships. `REQUIRE_JAMESDSP=1` makes its absence fatal.

`SIGN=1` needs your release keys in `~/rs4-release-keys` (mode 700); they never go into a repo.
