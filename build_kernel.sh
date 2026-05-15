#!/bin/bash
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
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

echo "[*] Fixing kernel version to match stock 4.14.150-gf3a84757f21f-ab6216664..."
sed -i 's/^SUBLEVEL = .*/SUBLEVEL = 150/' "${KERNEL_DIR}/Makefile"
find "${KERNEL_ROOT}" \( -name "localversion*" -o -name "localversion" \) -type f -exec echo "  Removing: {}" \; -delete 2>/dev/null
sed -i '/CONFIG_LOCALVERSION/d' "${DEFCONFIG}"
echo 'CONFIG_LOCALVERSION="-gf3a84757f21f-ab6216664"' >> "${DEFCONFIG}"
sed -i '/CONFIG_LOCALVERSION_AUTO/d' "${DEFCONFIG}"
echo '# CONFIG_LOCALVERSION_AUTO is not set' >> "${DEFCONFIG}"
export LOCALVERSION=""

echo "[*] Building kernel..."
cd "${KERNEL_ROOT}"

export ARCH=arm64
export JOBS
BUILD_CONFIG=${KERNEL_DIR}/build.config.no-cfi build/build.sh 2>&1 || {
    echo "[!] Build failed."
    exit 1
}

echo "[*] Build complete!"

echo "[*] Kernel version:"
cat "${KERNEL_ROOT}/out/android-msm-floral-4.14/private/msm-google/include/generated/utsrelease.h" 2>/dev/null || \
    grep -r "UTS_RELEASE" "${KERNEL_ROOT}/out" --include="utsrelease.h" 2>/dev/null | head -1

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

echo "[*] Creating boot.img from stock ramdisk..."

STOCK_RAMDISK="${REPO_ROOT}/stock_ramdisk.gz"
STOCK_DTB_GZ="${REPO_ROOT}/stock_dtb.bin.gz"
STOCK_HEADER="${REPO_ROOT}/stock_header.bin"

if [ ! -f "${STOCK_RAMDISK}" ] || [ ! -f "${STOCK_HEADER}" ]; then
    echo "[!] stock_ramdisk.gz or stock_header.bin not found, cannot create boot.img"
    echo "[!] Uploading kernel images only"
    ls -la "${OUTPUT_DIR}/"
    exit 0
fi

gunzip -k -c "${STOCK_DTB_GZ}" > /tmp/stock_dtb.bin 2>/dev/null
STOCK_DTB="/tmp/stock_dtb.bin"

BOOT_IMG_CREATED=false
export KERNEL_IMAGE_PATH="${KERNEL_IMAGE}"
export STOCK_RAMDISK
export STOCK_DTB
export STOCK_HEADER
export OUTPUT_DIR

python3 << 'PYEOF' && BOOT_IMG_CREATED=true
import struct, sys, os

kernel_path = os.environ["KERNEL_IMAGE_PATH"]
ramdisk_path = os.environ["STOCK_RAMDISK"]
dtb_path = os.environ["STOCK_DTB"]
header_path = os.environ["STOCK_HEADER"]
output_path = os.environ["OUTPUT_DIR"] + "/boot.img"

with open(header_path, "rb") as f:
    header = bytearray(f.read())
with open(kernel_path, "rb") as f:
    new_kernel = f.read()
with open(ramdisk_path, "rb") as f:
    ramdisk = f.read()
with open(dtb_path, "rb") as f:
    dtb = f.read()

PS = struct.unpack_from('<I', header, 36)[0]

struct.pack_into('<I', header, 8, len(new_kernel))

out = bytearray(header)
out.extend(new_kernel)
out.extend(b'\x00' * ((PS - (len(new_kernel) % PS)) % PS))
out.extend(ramdisk)
out.extend(b'\x00' * ((PS - (len(ramdisk) % PS)) % PS))
out.extend(dtb)
out.extend(b'\x00' * ((PS - (len(dtb) % PS)) % PS))

with open(output_path, "wb") as f:
    f.write(out)
print(f'boot.img: {len(out)} bytes ({len(out)/1024/1024:.1f} MB)')
print(f'  kernel: {len(new_kernel)} bytes')
print(f'  ramdisk: {len(ramdisk)} bytes')
print(f'  dtb: {len(dtb)} bytes')
PYEOF

rm -f /tmp/stock_dtb.bin

if [ "${BOOT_IMG_CREATED}" = "true" ] && [ -f "${OUTPUT_DIR}/boot.img" ]; then
    echo "  -> boot.img ($(du -sh ${OUTPUT_DIR}/boot.img | cut -f1))"
else
    echo "[!] boot.img creation failed, uploading kernel images only"
fi

echo "[*] Collecting kernel modules..."
MODULES_DIR="${OUTPUT_DIR}/modules"
mkdir -p "${MODULES_DIR}"

KO_COUNT=0
for ko in $(find "${ACTUAL_OUT}" -name "*.ko" -type f 2>/dev/null); do
    cp "$ko" "${MODULES_DIR}/"
    KO_COUNT=$((KO_COUNT + 1))
done

if [ ${KO_COUNT} -gt 0 ]; then
    echo "[*] Creating modules.zip (${KO_COUNT} modules)..."
    cd "${MODULES_DIR}"
    ls *.ko | sed 's/\.ko$//' > modules.load
    depmod -b . *.ko 2>/dev/null || true
    cd "${OUTPUT_DIR}"
    zip -j modules.zip modules/*.ko modules/modules.load 2>/dev/null
    rm -rf "${MODULES_DIR}"
    echo "  -> modules.zip ($(du -sh ${OUTPUT_DIR}/modules.zip | cut -f1), ${KO_COUNT} modules)"
else
    echo "[!] No kernel modules found"
    rm -rf "${MODULES_DIR}"
fi

ls -la "${OUTPUT_DIR}/"
echo "[*] Done!"
