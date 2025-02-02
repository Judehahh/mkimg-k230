#!/usr/bin/env bash

set -eu

# ci redefined
BUILD_DIR=${BUILD_DIR:-build}
OUTPUT_DIR=${OUTPUT_DIR:-output}
VENV_DIR=${VENV_DIR:-venv}
ABI=${ABI:-rv64}
BOARD=${BOARD:-canmv}
ARCH=${ARCH:-riscv}
CROSS_COMPILE=${CROSS_COMPILE:-riscv64-unknown-linux-gnu-}
TIMESTAMP=${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}

DISTRO=${DISTRO:-revyos} # revyos or debian or archlinux
CHROOT_TARGET=${CHROOT_TARGET:-target}
ROOTFS_IMAGE_SIZE=2G
ROOTFS_IMAGE_FILE="k230_root.ext4"

LINUX_BUILD=${LINUX_BUILD:-build}
OPENSBI_BUILD=${OPENSBI_BUILD:-build}
UBOOT_BUILD=${UBOOT_BUILD:-build-uboot}

mkdir -p ${BUILD_DIR} ${OUTPUT_DIR} ${CHROOT_TARGET}

OUTPUT_DIR=$(readlink -f ${OUTPUT_DIR})
SCRIPT_DIR=$(readlink -f $(dirname $0))

function build_linux() {
  pushd linux
  {
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${LINUX_BUILD} k230_evb_linux_enable_vector_defconfig
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${LINUX_BUILD} -j$(nproc) dtbs
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${LINUX_BUILD} -j$(nproc)

    cp -v ${LINUX_BUILD}/vmlinux ${OUTPUT_DIR}/vmlinux_${ABI}
    cp -v ${LINUX_BUILD}/arch/riscv/boot/Image ${OUTPUT_DIR}/Image_${ABI}
    cp -v Documentation/admin-guide/kdump/gdbmacros.txt ${OUTPUT_DIR}/gdbmacros_${ABI}.txt
    cp -v ${LINUX_BUILD}/arch/riscv/boot/dts/canaan/k230_evb.dtb ${OUTPUT_DIR}/k230_evb_${ABI}.dtb
    cp -v ${LINUX_BUILD}/arch/riscv/boot/dts/canaan/k230_canmv.dtb ${OUTPUT_DIR}/k230_canmv_${ABI}.dtb
  }
  popd
}

function build_opensbi() {
  pushd opensbi
  {
    make \
      ARCH=${ARCH} \
      CROSS_COMPILE=${CROSS_COMPILE} \
      O=${OPENSBI_BUILD} \
      PLATFORM=generic \
      FW_PAYLOAD=y \
      FW_FDT_PATH=${OUTPUT_DIR}/k230_${BOARD}_${ABI}.dtb \
      FW_PAYLOAD_PATH=${OUTPUT_DIR}/Image_${ABI} \
      FW_TEXT_START=0x0 \
      -j $(nproc)
    cp -v ${OPENSBI_BUILD}/platform/generic/firmware/fw_payload.bin ${OUTPUT_DIR}/k230_${BOARD}_${ABI}.bin
  }
  popd
}

function build_uboot() {
  python3 -m venv ${VENV_DIR}
  source ${VENV_DIR}/bin/activate
  pip install gmssl
  pushd uboot
  {
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${UBOOT_BUILD} k230_${BOARD}_defconfig
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${UBOOT_BUILD} -j$(nproc)
    cp -av ${UBOOT_BUILD}/u-boot-spl-k230.bin ${OUTPUT_DIR}/u-boot-spl-k230_${BOARD}.bin
    cp -av ${UBOOT_BUILD}/fn_u-boot.img ${OUTPUT_DIR}/fn_u-boot_${BOARD}.img
  }
  popd
  deactivate
}

function build_rootfs() {
  truncate -s ${ROOTFS_IMAGE_SIZE} ${OUTPUT_DIR}/${ROOTFS_IMAGE_FILE}
  mkfs.ext4 -F -L rootfs ${OUTPUT_DIR}/${ROOTFS_IMAGE_FILE}

  mount ${OUTPUT_DIR}/${ROOTFS_IMAGE_FILE} ${CHROOT_TARGET}

  if [[ $DISTRO == "archlinux" ]]; then
    # Building rootfs
    pacstrap \
      -C ./extra-riscv64.conf \
      -M \
      $CHROOT_TARGET \
      base

    # Set default mirror to https://mirror.iscas.ac.cn/archriscv/repo/
    sed -E -i 's|#(Server = https://mirror\.iscas\.ac\.cn/archriscv/repo/\$repo)|\1|' $CHROOT_TARGET/etc/pacman.d/mirrorlist

    # Clean up pacman package cache...
    yes y | pacman \
    --sysroot $CHROOT_TARGET \
    --sync --clean --clean

    # Set root password (Default: archriscv)
    usermod --root $(realpath $CHROOT_TARGET) --password $(openssl passwd -6 archriscv) root

    chroot $CHROOT_TARGET /bin/bash <<EOF
# pacman source update
pacman -Syy

# Change hostname
echo ${DISTRO}-${BOARD} > /etc/hostname
echo 127.0.1.1 ${DISTRO}-${BOARD} >> /etc/hosts

# Set default timezone to Asia/Shanghai
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

# Network related
echo -e "[Match]\nName=en*\n\n[Network]\nDHCP=yes" > /etc/systemd/network/default.network
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service

exit
EOF
  else
    if [[ $DISTRO == "revyos" ]]; then
      mmdebstrap --architectures=riscv64 \
        --include="ca-certificates locales dosfstools bash iperf3 revyos-keyring \
        sudo bash-completion network-manager openssh-server systemd-timesyncd cloud-utils" \
        sid "$CHROOT_TARGET" \
        "deb https://mirror.iscas.ac.cn/revyos/revyos-addons/ revyos-addons main" \
        "deb https://mirror.iscas.ac.cn/revyos/revyos-base/ sid main contrib non-free non-free-firmware"
    else
      mmdebstrap --architectures=riscv64 \
        --include="ca-certificates locales dosfstools bash iperf3 debian-keyring \
        sudo bash-completion network-manager openssh-server systemd-timesyncd cloud-utils" \
        sid "$CHROOT_TARGET" \
        "deb https://deb.debian.org/debian/ sid main contrib non-free non-free-firmware"
    fi

    chroot $CHROOT_TARGET /bin/bash <<EOF
# apt update
sed -i 's#deb [trusted=yes] http#deb http#g' /etc/apt/sources.list
apt update

# Add user
useradd -m -s /bin/bash -G adm,sudo debian
echo 'debian:debian' | chpasswd

# Change hostname
echo ${DISTRO}-${BOARD} > /etc/hostname
echo 127.0.1.1 ${DISTRO}-${BOARD} >> /etc/hosts

# Disable iperf3
systemctl disable iperf3

# Set default timezone to Asia/Shanghai
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

exit
EOF

    if [ ! -f revyos-release ]; then
      echo "$TIMESTAMP" >$CHROOT_TARGET/etc/revyos-release
    else
      cp -v revyos-release $CHROOT_TARGET/etc/revyos-release
    fi

    # clean source
    rm -vrf $CHROOT_TARGET/var/lib/apt/lists/*
  fi

  umount ${CHROOT_TARGET}
}

function build_img() {
  genimage --config configs/${BOARD}.cfg \
    --inputpath "${OUTPUT_DIR}" \
    --outputpath "${OUTPUT_DIR}" \
    --rootpath="$(mktemp -d)"
}

function fix_permissions() {
  chown -R $USER ${OUTPUT_DIR}
}

function cleanup_build() {
  check_euid_root
  pushd ${SCRIPT_DIR}
  {
    mountpoint -q ${CHROOT_TARGET} && umount -l ${CHROOT_TARGET}
    rm -rvf ${OUTPUT_DIR} ${BUILD_DIR} ${CHROOT_TARGET}
    rm -rvf uboot/${UBOOT_BUILD} opensbi/${OPENSBI_BUILD} linux/${LINUX_BUILD}
    rm -rvf ${VENV_DIR}
  }
  popd
}

function usage() {
  echo "Usage: $0 build/clean"
}

function fault() {
  usage
  exit 1
}

function check_euid_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
  fi
}

function main() {
  if [[ $# < 1 ]]; then
    fault
  fi

  if [ "$1" = "build" ]; then
    if [ "$2" = "linux" ]; then
      build_linux
    elif [ "$2" = "opensbi" ]; then
      build_opensbi
    elif [ "$2" = "uboot" ]; then
      build_uboot
    elif [ "$2" = "rootfs" ]; then
      check_euid_root
      build_rootfs
      fix_permissions
    elif [ "$2" = "img" ]; then
      build_img
    elif [ "$2" = "linux_opensbi_uboot" ]; then
      build_linux
      build_opensbi
      build_uboot
    elif [ "$2" = "all" ]; then
      check_euid_root
      build_linux
      build_opensbi
      build_uboot
      build_rootfs
      build_img
      fix_permissions
    else
      fault
    fi
  elif [ "$1" = "clean" ]; then
    cleanup_build
  else
    fault
  fi
}

main $@
