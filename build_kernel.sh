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

DIST_DIR="${KERNEL_ROOT}/out/dist"
OUT_DIR="${KERNEL_ROOT}/out"

for f in \
    "${DIST_DIR}/Image.lz4" \
    "${DIST_DIR}/dtbo.img" \
    "${OUT_DIR}/arch/arm64/boot/Image.lz4" \
    "${OUT_DIR}/arch/arm64/boot/dtbo.img" \
    ; do
    if [ -f "$f" ]; then
        cp "$f" "${OUTPUT_DIR}/"
        echo "  -> $(basename $f)"
    fi
done

for dtb in "${OUT_DIR}/arch/arm64/boot/dts/google/qcom-base/"sm8150*.dtb; do
    if [ -f "$dtb" ]; then
        cp "$dtb" "${OUTPUT_DIR}/"
        echo "  -> $(basename $dtb)"
    fi
done

ls -la "${OUTPUT_DIR}/"
echo "[*] Done!"
