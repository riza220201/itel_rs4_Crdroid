#!/bin/bash
# crdroid-tf.sh — regenerate the target-files package for release signing.
#
# WHY THIS IS A SEPARATE STEP: `mka bacon` DELETES the target-files intermediates when it finishes
# (vendor/lineage/build/tasks/bacon.mk ends with
#   rm -rf $(call intermediates-dir-for,PACKAGING,target_files)),
# so after a bacon build there is nothing left for sign_target_files_apks to sign.
#
# WHY IT MUST EXPORT BUILD_NUMBER: BUILD_NUMBER feeds ro.build.version.incremental AND FILE_NAME_TAG.
# Regenerating the target-files without it would rebuild build.prop with an eng/timestamp incremental
# and silently destroy the honest stock fingerprint
#   Itel/S666LN-OP/itel-S666LN:13/TP1A.220624.014/251212V1661:user/release-keys
# (that is exactly how the stale "lineage_S666LN-target_files-eng.nobody" tree came about).
# Keep this identical to crdroid-build-rc.sh.
export PATH=$HOME/bin:$PATH
export USE_CCACHE=1
export CCACHE_DIR=$HOME/.ccache
export BUILD_NUMBER=251212V1661

cd ~/crdroid || exit 2

source build/envsetup.sh
lunch lineage_S666LN-user || { echo "LUNCH_FAILED"; exit 2; }
date "+TF_START %F %T"
mka target-files-package
rc=$?
echo "TF_RC=$rc"
date "+TF_END %F %T"
ls -la out/target/product/S666LN/obj/PACKAGING/target_files_intermediates/*.zip 2>/dev/null
