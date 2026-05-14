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
echo " KernelSU: ${KERNELSU_VERSION}"
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

# Save the absolute root path of kernel_build
KERNEL_ROOT=$(pwd)
echo "[*] Kernel root: ${KERNEL_ROOT}"

CLANG_BIN="${KERNEL_ROOT}/prebuilts-master/clang/host/linux-x86/clang-r353983c/bin"
GCC_BIN="${KERNEL_ROOT}/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"
GCC32_BIN="${KERNEL_ROOT}/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin"
CLANG_LIB="${KERNEL_ROOT}/prebuilts-master/clang/host/linux-x86/clang-r353983c/lib64"

echo "[*] Verifying toolchains..."
echo "  Clang: $(ls ${CLANG_BIN}/clang 2>/dev/null || echo 'MISSING')"
echo "  ld.lld: $(ls ${CLANG_BIN}/ld.lld 2>/dev/null || echo 'MISSING')"
echo "  GCC ld: $(ls ${GCC_BIN}/aarch64-linux-android-ld 2>/dev/null || echo 'MISSING')"

echo "[*] Setting up KernelSU ${KERNELSU_VERSION}..."
cd ${KERNEL_DIR}
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s ${KERNELSU_VERSION}
cd "${KERNEL_ROOT}"

echo "[*] Applying KernelSU kernel patches..."
python3 "${GITHUB_WORKSPACE:-.}/patch_kernel.py" "${KERNEL_DIR}"

echo "[*] Fixing build compatibility issues..."
# Fix selinux classmap.h PF_MAX check for newer host headers
sed -i 's/#if PF_MAX > 44/#if PF_MAX > 50/' "${KERNEL_DIR}/security/selinux/include/classmap.h"
# Disable DT overlay build (dtc compatibility issue on newer hosts)
sed -i 's/CONFIG_BUILD_ARM64_DT_OVERLAY=y/# CONFIG_BUILD_ARM64_DT_OVERLAY is not set/' "${KERNEL_DIR}/arch/arm64/configs/floral_defconfig"

echo "[*] Building kernel..."
cd "${KERNEL_ROOT}/${KERNEL_DIR}"

export ARCH=arm64
export SUBARCH=arm64

export PATH="${CLANG_BIN}:${GCC_BIN}:${GCC32_BIN}:${PATH}"
export LD_LIBRARY_PATH="${CLANG_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "[*] Debug: PWD=${PWD}"
echo "[*] Debug: CLANG_BIN=${CLANG_BIN}"
ls -la "${CLANG_BIN}/clang" 2>/dev/null || echo "CLANG NOT FOUND at ${CLANG_BIN}"
ls -la "${CLANG_BIN}/ld.lld" 2>/dev/null || echo "ld.lld NOT FOUND at ${CLANG_BIN}"

echo "[*] Toolchain PATH:"
echo "  clang: $(which clang 2>/dev/null || echo 'NOT FOUND')"
echo "  ld.lld: $(which ld.lld 2>/dev/null || echo 'NOT FOUND')"
echo "  aarch64-linux-android-gcc: $(which aarch64-linux-android-gcc 2>/dev/null || echo 'NOT FOUND')"

echo "[*] Making defconfig..."
make O=out ARCH=arm64 \
    HOSTCFLAGS="-fcommon" \
    CC=clang \
    LD=ld.lld \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-android- \
    CROSS_COMPILE_ARM32=arm-linux-androideabi- \
    floral_defconfig

echo "[*] Building kernel (this may take a while)..."
make -j${JOBS} O=out \
    ARCH=arm64 \
    HOSTCFLAGS="-fcommon" \
    CC=clang \
    LD=ld.lld \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-android- \
    CROSS_COMPILE_ARM32=arm-linux-androideabi- \
    2>&1 || {
        echo "[!] Build failed."
        exit 1
    }

echo "[*] Build complete!"

echo "[*] Collecting build outputs..."
OUTPUT_DIR="${GITHUB_WORKSPACE:-.}/output"
mkdir -p "${OUTPUT_DIR}"

if [ -f out/arch/arm64/boot/Image.lz4 ]; then
    cp out/arch/arm64/boot/Image.lz4 "${OUTPUT_DIR}/"
    echo "  -> Image.lz4"
fi

if [ -f out/arch/arm64/boot/dtbo.img ]; then
    cp out/arch/arm64/boot/dtbo.img "${OUTPUT_DIR}/"
    echo "  -> dtbo.img"
fi

for dtb in out/arch/arm64/boot/dts/google/qcom-base/sm8150*.dtb; do
    if [ -f "$dtb" ]; then
        cp "$dtb" "${OUTPUT_DIR}/"
        echo "  -> $(basename $dtb)"
    fi
done

ls -la "${OUTPUT_DIR}/"
echo "[*] Done!"
