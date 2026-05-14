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
repo init -u ${MANIFEST_URL} -b ${MANIFEST_BRANCH} --depth=1 2>&1 | tail -3

echo "[*] Syncing kernel source (this may take a while)..."
repo sync -j${JOBS} -c --no-tags --no-clone-bundle 2>&1 | tail -5

echo "[*] Setting up KernelSU ${KERNELSU_VERSION}..."
cd ${KERNEL_DIR}
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s ${KERNELSU_VERSION}
cd ../..

echo "[*] Applying KernelSU kernel patches..."
python3 "${GITHUB_WORKSPACE:-.}/patch_kernel.py" "${KERNEL_DIR}"

echo "[*] Patching build.config for -fcommon..."
# Fix for GCC 10+ -fno-common default (yylloc multiple definition)
sed -i 's/make O=/make HOSTCFLAGS="-fcommon" O=/' build/build.sh

echo "[*] Building kernel..."
export ARCH=arm64
export JOBS
# Use the standard build script from kernel/build
# It reads build.config (-> build.config.no-cfi) which sets up toolchains
BUILD_CONFIG=private/msm-google/build.config.no-cfi build/build.sh 2>&1 | tail -30

echo "[*] Build complete!"

echo "[*] Collecting build outputs..."
OUTPUT_DIR="${GITHUB_WORKSPACE:-.}/output"
mkdir -p "${OUTPUT_DIR}"

OUT_DIR=$(pwd)/out

if [ -f "${OUT_DIR}/dist/Image.lz4" ]; then
    cp "${OUT_DIR}/dist/Image.lz4" "${OUTPUT_DIR}/"
    echo "  -> Image.lz4"
elif [ -f "${KERNEL_DIR}/out/arch/arm64/boot/Image.lz4" ]; then
    cp "${KERNEL_DIR}/out/arch/arm64/boot/Image.lz4" "${OUTPUT_DIR}/"
    echo "  -> Image.lz4"
fi

if [ -f "${OUT_DIR}/dist/dtbo.img" ]; then
    cp "${OUT_DIR}/dist/dtbo.img" "${OUTPUT_DIR}/"
    echo "  -> dtbo.img"
fi

for f in "${OUT_DIR}/dist/"sm8150*.dtb "${KERNEL_DIR}/out/arch/arm64/boot/dts/google/qcom-base/"sm8150*.dtb; do
    if [ -f "$f" ]; then
        cp "$f" "${OUTPUT_DIR}/"
        echo "  -> $(basename $f)"
    fi
done

ls -la "${OUTPUT_DIR}/"
echo "[*] Done!"
