#!/bin/bash

# critical task: fail on any error
set -e

source /usr/lib/k8r/variables.cfg

# Allow overriding image path with a parameter
LOCAL_IMAGE_PATH="$1"

if [ "$HTTP_IMAGE_URL" = "" -a "$LOCAL_IMAGE_PATH" = "" ] ; then
  echo "HTTP_IMAGE_URL setting was not configured and image path was not provided."
  echo "Run this as \"$0 /path/cotaining/\" image.img.xz (without image.img.xz part)"
  echo "or set HTTP_IMAGE_URL in variables.cfg"
  echo "Exiting now."
  exit 1
fi

ALL_DEV="`blkid`"
BOOT_DEV=`echo "$ALL_DEV" | grep 'LABEL="system-boot"'| head -n 1  | awk -F':' {'print $1'} `
IMAGE_DEV=`echo "$ALL_DEV" | grep 'LABEL="image"'| head -n 1  | awk -F':' {'print $1'} `

if [ "$LOCAL_IMAGE_PATH" = "" ] ; then
  #FIXME: Check free space before downloading.
  #FIXME: Add checksum verification.
  echo "Downloading boot archive from $HTTP_IMAGE_URL"
  curl -Lo /boot.tar.xz $HTTP_IMAGE_URL/boot.tar.xz
  echo "Downloading image from $HTTP_IMAGE_URL"
  curl -Lo /image.img.xz $HTTP_IMAGE_URL/image.img.xz
fi

if [ ! -r "$LOCAL_IMAGE_PATH"/image.img.xz ] ; then
  echo "ERROR: cannot read local installation image $LOCAL_IMAGE_PATH/image.img.xz. Exiting."
  exit 1
fi
if  ! xz -t $LOCAL_IMAGE_PATH/image.img.xz ; then
  echo "ERROR: local installation image $LOCAL_IMAGE_PATH/image.img.xz is not an xz archive. Exiting."
  exit 1
fi
if [ ! -r "$LOCAL_IMAGE_PATH"/boot.tar.xz ] ; then
  echo "ERROR: cannot read local boot archive $LOCAL_IMAGE_PATH/boot.tar.xz. Exiting."
exit 1
fi
if  ! xz -t $LOCAL_IMAGE_PATH/boot.tar.xz  ; then
  echo "ERROR: local boot archive $LOCAL_IMAGE_PATH/boot.tar.xz is not an xz archive. Exiting."
  exit 1
fi

# Remote images are downloaded to / when LOCAL_IMAGE_PATH is empty, so the
# following extraction procedure works for both local and remote cases.
echo "Writing image $LOCAL_IMAGE_PATH/image.img.xz to image partition $IMAGE_DEV"
unxz -v --stdout $LOCAL_IMAGE_PATH/image.img.xz | dd of=$IMAGE_DEV bs=100M
echo "Re-formatting boot partition to make sure it's clean."
umount $BOOT_DEV
mkfs.vfat $BOOT_DEV
fatlabel $BOOT_DEV system-boot
echo "Mounting /boot/firmware mountpoint where $BOOT_DEV is expected"
echo "to be mounted. There can be an error if the layout changes in future"
echo "releases of Ubuntu. In this case, this should be reported as a bug."
mount /boot/firmware
echo "Extracting updated boot and firmware files."
tar xvf $LOCAL_IMAGE_PATH/boot.tar.xz -C /boot/firmware
echo "Unmounting /boot/firmware partition for future operations."
umount /boot/firmware
echo "Verifying FS at target partitions $BOOT_DEV"
fsck.vfat -a $BOOT_DEV || true
echo "Verifying FS at target partition $IMAGE_DEV"
# e2fsck will return error when fixing a corrupted FS, so need to suppress it
e2fsck -yf $IMAGE_DEV || true
mount $BOOT_DEV
echo "Resizing fs on image partition $IMAGE_DEV to all available space"
resize2fs $IMAGE_DEV
echo "Injecting installation image into FS on image partition"
IMAGE_PART_DIR=`mktemp -d`
mount $IMAGE_DEV $IMAGE_PART_DIR
cp $LOCAL_IMAGE_PATH/image.img.xz $IMAGE_PART_DIR/
umount $IMAGE_PART_DIR
# if there were any changes, they will need yet another fsck to mark it clean
e2fsck -yf $IMAGE_DEV || true
echo "Resizing fs on working partition $IMAGE_DEV to all available space"
resize2fs $IMAGE_DEV
echo "Ensuring proper label on boot partition"
fatlabel $BOOT_DEV system-boot
echo "Ensuring proper label on image partition"
e2label $IMAGE_DEV image
echo "Done updating partitions"
# set error handling back to normal
set +e
