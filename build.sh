#!/bin/bash

# Fail on any error. We don't want do break existing images
set -e

UBUNTU_CONTAINER_VERSION="24.04"

# For non-arm64 arch, add a wrapper container with qemu handlers for arm64
# Once containerized, "in_arm64_container" flag is set to go to further steps
if [ "`uname -m`" != "arm64" \
      -a "`echo $@ | grep in_arm64_container`" = "" \
      -a "`echo $@ | grep in_final_container`" = "" ] ; then
  echo "Wrapping build inside multiarch-enabled docker container"
  docker run \
    --privileged \
    --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v /dev:/dev \
    -v `pwd`:/wrapper_k8r \
    --rm \
    -it \
    ubuntu:$UBUNTU_CONTAINER_VERSION \
      sh -c "\
      cd /wrapper_k8r && \
      apt -y update && \
      bash ./install-docker.sh && \
      apt -y install binfmt-support qemu-user-static && \
      docker run --rm --privileged multiarch/qemu-user-static --reset -p yes && \
      /bin/bash /wrapper_k8r/build.sh in_arm64_container "$@" \
      "
  exit $?
fi


# Run all builds in docker. Flag "in_final_container" is set to indicate that
# this step was completed
if [ "`echo $@ | grep in_final_container`" = "" ] ; then
  echo "Running build in docker container"
  docker run \
    --privileged \
    --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v /dev:/dev \
    -v `pwd`:/k8r \
    --rm \
    -it \
    arm64v8/ubuntu:$UBUNTU_CONTAINER_VERSION \
    /bin/bash /k8r/build.sh in_final_container $@
  exit $?
fi

# the scripts are ran from project's directory, not some installation path
cd `dirname $0`

source ./variables.cfg

if [ -z "$IMAGE" -o -z "$K8S_VERSION" ] ; then
  echo "Please configure variables.cfg before running this script"
  exit 1
fi

# include sbin dirs, in particular, for parted
export PATH=/sbin:/usr/sbin:/usr/local/sbin:$PATH

# Ensure that working files are not mounted from previous installations
for files in images/bootable_image.img images/image.img images/boot.img ; do
  if [ "`losetup | grep $files`" != "" ] ; then
    echo "File $files is already mounted as loopback device."
    echo "This could be leftovers of a previous failed run of this script."
    echo "Please check the output of 'losetup' command, detach the loopback"
    echo "devices with 'losetup -d LOOPBACK_DEVICE_HERE' and re-run."
    echo "I can automatically detach ALL of the listed (DANGEROUS):"
    losetup
    echo "Approve (yes/NO):"
    read answ
    if [ "$answ" = "yes" ] ; then
      losetup -D
    else
      exit 1
    fi
  fi
done

# FIXME: unused at the moment.
# inject variables.cfg into images. No other actions will be done
if [ "$MODE" = "inject-config" ] ; then
  echo "Injecting variables into image images/image.img"
  mount -o loop images/image.img /mnt
  cp variables.cfg /mnt/usr/lib/k8r/variables.cfg
  umount /mnt
  echo "Injecting variables into image images/bootable_image.img"
  LODEV=`losetup -P -f --show images/bootable_image.img`
  mount ${LODEV}p1 /mnt
  cp variables.cfg /mnt/usr/lib/k8r/variables.cfg
  umount /mnt
  losetup -d $LODEV
  echo "Done injecting variables"
  exit
fi

echo "Installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt -y update
apt -y install parted udev whois xz-utils bc dosfstools

echo "Partitions on image $IMAGE:"
parted -s $IMAGE print
if [ "$?" != 0 ] ; then
  echo "Image $IMAGE seems to be invalid."
  echo "Please try another image."
  exit 1
fi

if [ ! -r images ] ; then
  echo "Directory 'images' does not exist yet, creating it now"
  mkdir images
fi

#This is going to be a resulting image which can be flashed onto nodes' disk
echo "Copying original image to output directory for further modifications"
cp $IMAGE images/bootable_image.img

DEVICE=`losetup -P -f --show images/bootable_image.img`

# for mmcblk* and loop* devices, set "p" suffix for partitions
if [ "`echo $DEVICE | grep -E 'mmcblk|loop'`" != "" ] ; then
  DEVICEPART=${DEVICE}p
else
  DEVICEPART=${DEVICE}
fi

echo "Preparing image for initialization"
K8R_IMAGE_MOUNT_DIR="/mnt"
source prepare_image.sh

echo "Initializing image"
if [ ! -r "$K8R_IMAGE_MOUNT_DIR/etc/resolv.conf" ] ; then
  set -e
  echo "Image does not have resolv.conf. Mounting it for bootstrap."
  # Move it if it is a dead symlink (not caught by -r), ignore any errors
  mv $K8R_IMAGE_MOUNT_DIR/etc/resolv.conf $K8R_IMAGE_MOUNT_DIR/etc/resolv.conf.bak || true
  touch $K8R_IMAGE_MOUNT_DIR/etc/resolv.conf
  mount --bind /etc/resolv.conf $K8R_IMAGE_MOUNT_DIR/etc/resolv.conf
fi

echo "Adding user and setting password for user ubuntu"
chroot $K8R_IMAGE_MOUNT_DIR /usr/bin/cloud-init single -n users_groups
if [ ! -r password_hash ] ; then
  echo "File \"password_hash\" does not exist, using password \"ubuntu\""
  PASSWD_HASH=`echo ubuntu | mkpasswd  -m sha-512 -s`
else
  echo "Using password hash from file \"password_hash\""
  PASSWD_HASH=`cat password_hash`
fi

sed -i 's#ubuntu:!#ubuntu:'$PASSWD_HASH'#g' $K8R_IMAGE_MOUNT_DIR/etc/shadow
echo "Enabling password authentication via ssh"
sed -i 's/^PasswordAuthentication no\ *$/PasswordAuthentication yes /g' $K8R_IMAGE_MOUNT_DIR/etc/ssh/sshd_config
if [ "`grep -E '^PasswordAuthentication' $K8R_IMAGE_MOUNT_DIR/etc/ssh/sshd_config`" = "" ] ; then
  echo "No previous setting for Password Authentication was found. Adding now."
  echo >> $K8R_IMAGE_MOUNT_DIR/etc/ssh/sshd_config
  echo 'PasswordAuthentication yes' >> $K8R_IMAGE_MOUNT_DIR/etc/ssh/sshd_config
fi
ADDITIONAL_SSH_PASSWORD_CONFIG="`grep -ElR PasswordAuthentication $K8R_IMAGE_MOUNT_DIR/etc/ssh/sshd_config.d/ || true`"
if [ "$ADDITIONAL_SSH_PASSWORD_CONFIG" != "" ] ; then
  echo "Additional ssh password login config found in $ADDITIONAL_SSH_PASSWORD_CONFIG"
  echo "Removing the directive."
  sed -i 's/^PasswordAuthentication.*//g' $ADDITIONAL_SSH_PASSWORD_CONFIG
fi

# FIXME: if the kernel gets updated by the script below (it shouldn't), then
# FIXME: firmware updates will NOT be included into bootable_image.img
echo "Running bootstrap script in chroot"
chroot $K8R_IMAGE_MOUNT_DIR /bin/bash /usr/lib/k8r/tasks/bootstrap_image.sh

if [ "`mount | grep resolv.conf`" != "" ] ; then
  echo "Unmounting temporary resolv.conf from image"
  umount $K8R_IMAGE_MOUNT_DIR/etc/resolv.conf
  rm -f $K8R_IMAGE_MOUNT_DIR/etc/resolv.conf
  mv $K8R_IMAGE_MOUNT_DIR/etc/resolv.conf.bak $K8R_IMAGE_MOUNT_DIR/etc/resolv.conf || true
fi

echo "Creating boot/firmware partition archive images/boot.tar.xz"
tar -cJvf images/boot.tar.xz -C /mnt/boot .
echo "WARNING"
echo "WARNING: boot.img is deprecated and will not be built after version 1.31"
echo "WARNING"
echo "Building DEPRECATED images/boot.img"
echo "Creating empty boot image with vfat FS"
dd if=/dev/zero of=images/boot.img bs=200M count=1
mkfs.vfat images/boot.img
mkdir /mnt/bootimg
mount -o loop images/boot.img /mnt/bootimg
echo "Copying boot partition contents to boot image."
cp -Ra /mnt/boot/* /mnt/bootimg/
umount /mnt/bootimg
echo "Cleanup: Removing previous images/boot.img.xz, if any"
rm -f images/boot.img.xz
echo "Compressing images/boot.img to images/boot.img.xz"
xz -v -T0 images/boot.img

echo "Dumping image partition to images/image.img for use in online upgrades."
dd if=${DEVICEPART}2 of=images/image.img status=progress
echo "Done"
echo "Shrinking image FS to minimum possible space plus 50M reserve"
# fsck will return non-zero if it fixes FS, so need to suppress it since
# we have 'set -e' enabled
e2fsck -yf images/image.img || true
IMAGE_BLOCK_SIZE=`dumpe2fs -h images/image.img 2>/dev/null | grep 'Block size' | awk {'print $NF'}`
IMAGE_MIN_SIZE=`resize2fs -P images/image.img | tail -n 1 | awk {'print $NF'}`
IMAGE_SIZE_TARGET=`echo $IMAGE_MIN_SIZE+50*1024/$IMAGE_BLOCK_SIZE | bc`
resize2fs images/image.img ${IMAGE_SIZE_TARGET}
# xz will not overwrite an existing image, need to clean up manually
echo "Cleanup: Removing previous images/image.img.xz, if any"
rm -f images/image.img.xz
echo "Removing any labels from image.img to avoid boot conflicts on upgrade"
e2label images/image.img ""
echo "Compressing images/image.img to images/image.img.xz"
xz -v -T0 images/image.img

echo "Injecting boot.img.xz into bootable_image.img"
cp images/boot.img.xz $K8R_IMAGE_MOUNT_DIR/
echo "Injecting image.img.xz into bootable_image.img"
cp images/image.img.xz $K8R_IMAGE_MOUNT_DIR/

echo "Cleanup: detaching loop device $DEVICE"
losetup -d $DEVICE
