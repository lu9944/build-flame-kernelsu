#!/bin/bash
set -eo pipefail

MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
MANIFEST_BRANCH="android-msm-coral-4.14-android10-c2f2"
KERNELSU_VERSION="v0.9.5"
KERNEL_DIR="private/msm-google"
JOBS=$(nproc)

echo "============================================"
echo " KernelSU Kernel Builder for Pixel 4 (flame)"
echo " Kernel: ${MANIFEST_BRANCH}"
echo " KernelSU: ${KERNELSU_VERSION} (kprobe)"
echo "============================================"

echo "[*] Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    git python3 bc bison flex libssl-dev libelf-dev \
    build-essential gcc-aarch64-linux-gnu \
    libc6-dev-arm64-cross gcc-arm-linux-gnueabi \
    lz4 cpio libncurses5-dev wget curl pkg-config \
    > /dev/null 2>&1

echo "[*] Installing repo tool..."
mkdir -p ~/bin
curl -s https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
export PATH=~/bin:$PATH

echo "[*] Initializing repo..."
rm -rf kernel_build
mkdir kernel_build
cd kernel_build
git config --global user.name "build"
git config --global user.email "build@local"
repo init -u ${MANIFEST_URL} -b ${MANIFEST_BRANCH} -g all --depth=1 2>&1 | tail -3

echo "[*] Syncing kernel source (this may take a while)..."
repo sync -j${JOBS} -c --no-tags --no-clone-bundle 2>&1 | tail -5

KERNEL_ROOT=$(pwd)
echo "[*] Kernel root: ${KERNEL_ROOT}"

echo "[*] Replacing kernel/build with old version that has build.sh..."
rm -rf build
git clone --depth=1 -b android-10.0.0_r12 https://android.googlesource.com/kernel/build build 2>&1 | tail -3

echo "[*] Verifying toolchains..."
CLANG_BIN="${KERNEL_ROOT}/prebuilts-master/clang/host/linux-x86/clang-r353983c/bin"
echo "  clang: $(ls ${CLANG_BIN}/clang 2>/dev/null || echo 'MISSING')"
echo "  ld.lld: $(ls ${CLANG_BIN}/ld.lld 2>/dev/null || echo 'MISSING')"

echo "[*] Setting up KernelSU ${KERNELSU_VERSION} (kprobe method)..."
cd ${KERNEL_DIR}
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s ${KERNELSU_VERSION}
cd "${KERNEL_ROOT}"

echo "[*] Enabling KPROBES in defconfig..."
DEFCONFIG="${KERNEL_DIR}/arch/arm64/configs/floral_defconfig"
grep -q "CONFIG_KPROBES=y" "${DEFCONFIG}" || echo "CONFIG_KPROBES=y" >> "${DEFCONFIG}"

echo "[*] Fixing build compatibility issues..."
sed -i 's/#if PF_MAX > 44/#if PF_MAX > 50/' "${KERNEL_DIR}/security/selinux/include/classmap.h"
sed -i 's/CONFIG_BUILD_ARM64_DT_OVERLAY=y/# CONFIG_BUILD_ARM64_DT_OVERLAY is not set/' "${DEFCONFIG}"
# Remove check_defconfig to avoid savedefconfig mismatch
sed -i 's/check_defconfig && //' "${KERNEL_DIR}/build.config.no-cfi"

echo "[*] Building kernel..."
cd "${KERNEL_ROOT}"

export ARCH=arm64
export JOBS
BUILD_CONFIG=${KERNEL_DIR}/build.config.no-cfi build/build.sh 2>&1 || {
    echo "[!] Build failed."
    exit 1
}

echo "[*] Build complete!"

echo "[*] Collecting build outputs..."
OUTPUT_DIR="${GITHUB_WORKSPACE:-.}/output"
mkdir -p "${OUTPUT_DIR}"

# build/build.sh puts output in out/dist/, kernel objects in out/arch/arm64/boot/
DIST_DIR="${KERNEL_ROOT}/out/dist"
BOOT_DIR="${KERNEL_ROOT}/out/arch/arm64/boot"

echo "[*] Searching for kernel images..."
find "${KERNEL_ROOT}/out" -name "Image.lz4*" -o -name "*.dtb" -o -name "dtbo.img" 2>/dev/null | head -20

KERNEL_IMAGE=""
for f in \
    "${DIST_DIR}/Image.lz4" \
    "${BOOT_DIR}/Image.lz4" \
    "${DIST_DIR}/Image.lz4-dtb" \
    "${BOOT_DIR}/Image.lz4-dtb" \
    ; do
    if [ -f "$f" ]; then
        cp "$f" "${OUTPUT_DIR}/"
        echo "  -> $(basename $f)"
        if [ -z "${KERNEL_IMAGE}" ]; then
            KERNEL_IMAGE="$f"
        fi
    fi
done

for dtb in "${BOOT_DIR}/dts/google/qcom-base/"sm8150*.dtb "${DIST_DIR}/"sm8150*.dtb; do
    if [ -f "$dtb" ]; then
        cp "$dtb" "${OUTPUT_DIR}/"
        echo "  -> $(basename $dtb)"
    fi
done

if [ -f "${DIST_DIR}/dtbo.img" ]; then
    cp "${DIST_DIR}/dtbo.img" "${OUTPUT_DIR}/"
    echo "  -> dtbo.img"
fi

echo "[*] Creating boot.img..."

# Get mkbootimg
mkdir -p /tmp/mkbootimg
curl -sL "https://android.googlesource.com/platform/system/tools/mkbootimg/+/refs/heads/master/mkbootimg.py?format=TEXT" | base64 -d > /tmp/mkbootimg/mkbootimg.py
curl -sL "https://android.googlesource.com/platform/system/tools/mkbootimg/+/refs/heads/master/gki/generate_gki_certificate.py?format=TEXT" | base64 -d > /tmp/mkbootimg/generate_gki_certificate.py 2>/dev/null || true
chmod +x /tmp/mkbootimg/mkbootimg.py

# Create minimal ramdisk
MINITRD="/tmp/mkbootimg/ramdisk.cpio.gz"
echo "minimal ramdisk" | cpio -o -H newc 2>/dev/null | gzip > "${MINITRD}"

# Find DTB for flame
DTB_FILE=""
for dtb in \
    "${OUTPUT_DIR}/sm8150-v2.dtb" \
    "${OUTPUT_DIR}/sm8150.dtb" \
    "${BOOT_DIR}/dts/google/qcom-base/sm8150-v2.dtb" \
    "${BOOT_DIR}/dts/google/qcom-base/sm8150.dtb" \
    ; do
    if [ -f "$dtb" ]; then
        DTB_FILE="$dtb"
        break
    fi
done

MKBOOTIMG_ARGS="--kernel ${KERNEL_IMAGE} --ramdisk ${MINITRD}"
MKBOOTIMG_ARGS="${MKBOOTIMG_ARGS} --cmdline 'console=ttyMSM0,115200n8 androidboot.console=ttyMSM0 printk.devkmsg=on msm_rtb.filter=0x237 ehci-hcd.park=3 service_locator.enable=1 firmware_class.path=/vendor/firmware_mnt/image cgroup.memory=nokmem lpm_levels.sleep_disabled=1 loop.max_part=7 androidboot.boot_devices=soc/1d84000.ufshc buildvariant=userdebug'"
MKBOOTIMG_ARGS="${MKBOOTIMG_ARGS} --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100"
MKBOOTIMG_ARGS="${MKBOOTIMG_ARGS} --os_version 10.0.0 --os_patch_level 2020-03-05 --header_version 2"

if [ -n "${DTB_FILE}" ]; then
    MKBOOTIMG_ARGS="${MKBOOTIMG_ARGS} --dtb ${DTB_FILE}"
    echo "  Using DTB: $(basename $DTB_FILE)"
fi

python3 /tmp/mkbootimg/mkbootimg.py ${MKBOOTIMG_ARGS} --output "${OUTPUT_DIR}/boot.img" 2>&1 || {
    echo "[!] mkbootimg failed, trying without --dtb..."
    MKBOOTIMG_ARGS="--kernel ${KERNEL_IMAGE} --ramdisk ${MINITRD}"
    MKBOOTIMG_ARGS="${MKBOOTIMG_ARGS} --cmdline 'console=ttyMSM0,115200n8 androidboot.console=ttyMSM0 printk.devkmsg=on msm_rtb.filter=0x237 ehci-hcd.park=3 service_locator.enable=1 firmware_class.path=/vendor/firmware_mnt/image cgroup.memory=nokmem lpm_levels.sleep_disabled=1 loop.max_part=7 androidboot.boot_devices=soc/1d84000.ufshc buildvariant=userdebug'"
    MKBOOTIMG_ARGS="${MKBOOTIMG_ARGS} --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100"
    MKBOOTIMG_ARGS="${MKBOOTIMG_ARGS} --os_version 10.0.0 --os_patch_level 2020-03-05 --header_version 2"
    python3 /tmp/mkbootimg/mkbootimg.py ${MKBOOTIMG_ARGS} --output "${OUTPUT_DIR}/boot.img"
}

if [ -f "${OUTPUT_DIR}/boot.img" ]; then
    echo "  -> boot.img created"
fi

ls -la "${OUTPUT_DIR}/"
echo "[*] Done!"
