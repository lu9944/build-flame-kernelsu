#!/bin/bash
set -eo pipefail

MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
MANIFEST_BRANCH="android-msm-coral-4.14-android10-qpr1"
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

# build/build.sh uses OUT_DIR like out/android-msm-floral-4.14/
ACTUAL_OUT=$(find "${KERNEL_ROOT}/out" -maxdepth 2 -name "dist" -type d 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
if [ -z "${ACTUAL_OUT}" ]; then
    ACTUAL_OUT="${KERNEL_ROOT}/out"
fi
DIST_DIR="${ACTUAL_OUT}/dist"
BOOT_DIR="${ACTUAL_OUT}/private/msm-google/arch/arm64/boot"

echo "[*] OUT_DIR: ${ACTUAL_OUT}"
echo "[*] Searching for kernel images..."
find "${KERNEL_ROOT}/out" -name "Image.lz4*" -o -name "*.dtb" 2>/dev/null | head -20

KERNEL_IMAGE=""
for f in \
    "${DIST_DIR}/Image.lz4" \
    "${BOOT_DIR}/Image.lz4" \
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

for dtb in $(find "${ACTUAL_OUT}" -name "sm8150*.dtb" 2>/dev/null); do
    cp "$dtb" "${OUTPUT_DIR}/"
    echo "  -> $(basename $dtb)"
done

if [ -f "${DIST_DIR}/dtbo.img" ]; then
    cp "${DIST_DIR}/dtbo.img" "${OUTPUT_DIR}/"
    echo "  -> dtbo.img"
fi

if [ -z "${KERNEL_IMAGE}" ]; then
    echo "[!] No kernel image found!"
    exit 1
fi

echo "[*] Kernel image: ${KERNEL_IMAGE}"

echo "[*] Creating boot.img..."
set +e

mkdir -p /tmp/mkbootimg

# Download mkbootimg.py from Android 10 release
curl -sL "https://android.googlesource.com/platform/system/tools/mkbootimg/+/refs/tags/android-10.0.0_r33/mkbootimg.py?format=TEXT" | base64 -d > /tmp/mkbootimg/mkbootimg.py 2>/dev/null
if [ ! -s /tmp/mkbootimg/mkbootimg.py ]; then
    curl -sL "https://raw.githubusercontent.com/nicholasgasior/gohper/master/scripts/mkbootimg.py" > /tmp/mkbootimg/mkbootimg.py 2>/dev/null
fi

# Create minimal ramdisk
MINITRD="/tmp/mkbootimg/ramdisk.cpio.gz"
mkdir -p /tmp/mkbootimg/rd && cd /tmp/mkbootimg/rd
echo "init" > init
find . | cpio -o -H newc 2>/dev/null | gzip > "${MINITRD}"
cd "${KERNEL_ROOT}"

BOOT_IMG_CREATED=false

if [ -s /tmp/mkbootimg/mkbootimg.py ]; then
    echo "[*] Using mkbootimg.py..."
    python3 /tmp/mkbootimg/mkbootimg.py \
        --kernel "${KERNEL_IMAGE}" \
        --ramdisk "${MINITRD}" \
        --cmdline "console=ttyMSM0,115200n8 androidboot.console=ttyMSM0 printk.devkmsg=on msm_rtb.filter=0x237 ehci-hcd.park=3 service_locator.enable=1 firmware_class.path=/vendor/firmware_mnt/image cgroup.memory=nokmem lpm_levels.sleep_disabled=1 loop.max_part=7 androidboot.boot_devices=soc/1d84000.ufshc" \
        --base 0x00000000 \
        --kernel_offset 0x00008000 \
        --ramdisk_offset 0x01000000 \
        --tags_offset 0x00000100 \
        --os_version 10.0.0 \
        --os_patch_level 2020-03-05 \
        --header_version 2 \
        --output "${OUTPUT_DIR}/boot.img" 2>&1 && BOOT_IMG_CREATED=true
fi

if [ "${BOOT_IMG_CREATED}" = "false" ]; then
    echo "[*] mkbootimg.py failed or unavailable, creating boot.img manually..."
    # Manual boot.img: header(1648 bytes) + page-aligned kernel + page-aligned ramdisk
    KERNEL_SIZE=$(stat -c%s "${KERNEL_IMAGE}")
    RAMDISK_SIZE=$(stat -c%s "${MINITRD}")
    PAGE_SIZE=4096
    KERNEL_PAGES=$(( (KERNEL_SIZE + PAGE_SIZE - 1) / PAGE_SIZE ))
    RAMDISK_PAGES=$(( (RAMDISK_SIZE + PAGE_SIZE - 1) / PAGE_SIZE ))
    BOOT_SIZE=$(( 1648 + KERNEL_PAGES * PAGE_SIZE + RAMDISK_PAGES * PAGE_SIZE ))

    # Write boot header (Android boot image header v0)
    python3 -c "
import struct, sys
kern = open('${KERNEL_IMAGE}', 'rb').read()
rd = open('${MINITRD}', 'rb').read()
cmdline = b'console=ttyMSM0,115200n8 androidboot.console=ttyMSM0'
PS = 4096
header = bytearray(1648)
# magic ANDROID!
header[0:8] = b'ANDROID!'
struct.pack_into('<I', header, 8, kern.__len__())     # kernel_size
struct.pack_into('<I', header, 12, 0x00008000)         # kernel_addr
struct.pack_into('<I', header, 16, rd.__len__())        # ramdisk_size
struct.pack_into('<I', header, 20, 0x01000000)         # ramdisk_addr
struct.pack_into('<I', header, 24, 0x00000100)         # tags_addr
struct.pack_into('<I', header, 28, 0)                   # page_size
header[32:36] = b'\\x00\\x00\\x00\\x00'                # header_version = 0
header[36:64] = cmdline + b'\\x00' * (28 - cmdline.__len__())  # cmdline
header[64:1024] = b'\\x00' * 960                        # id + extra_cmdline
# pad kernel and ramdisk to page size
kern_pad = b'\\x00' * ((PS - kern.__len__() % PS) % PS)
rd_pad = b'\\x00' * ((PS - rd.__len__() % PS) % PS)
open('${OUTPUT_DIR}/boot.img', 'wb').write(header + kern + kern_pad + rd + rd_pad)
print(f'boot.img created: {header.__len__() + kern.__len__() + kern_pad.__len__() + rd.__len__() + rd_pad.__len__()} bytes')
" && BOOT_IMG_CREATED=true
fi

set -e

if [ "${BOOT_IMG_CREATED}" = "true" ] && [ -f "${OUTPUT_DIR}/boot.img" ]; then
    echo "  -> boot.img ($(du -sh ${OUTPUT_DIR}/boot.img | cut -f1))"
else
    echo "[!] boot.img creation failed, uploading kernel images only"
fi

ls -la "${OUTPUT_DIR}/"
echo "[*] Done!"
