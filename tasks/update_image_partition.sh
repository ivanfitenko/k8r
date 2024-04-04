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
  echo "Downloading boot image from $HTTP_IMAGE_URL"
  curl -Lo /boot.img.xz $HTTP_IMAGE_URL/boot.img.xz
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
if [ ! -r "$LOCAL_IMAGE_PATH"/boot.img.xz ] ; then
  echo "ERROR: cannot read local boot image $LOCAL_IMAGE_PATH/boot.img.xz. Exiting."
exit 1
fi
if  ! xz -t $LOCAL_IMAGE_PATH/boot.img.xz  ; then
  echo "ERROR: local boot image $LOCAL_IMAGE_PATH/boot.img.xz is not an xz archive. Exiting."
  exit 1
fi

# Remote images are downloaded to / when LOCAL_IMAGE_PATH is empty, so the
# following extraction procedure works for both local and remote cases.
echo "Writing image $LOCAL_IMAGE_PATH/boot.img.xz to image partition $BOOT_DEV"
unxz -v --stdout $LOCAL_IMAGE_PATH/boot.img.xz | dd of=$BOOT_DEV bs=100M
echo "Writing image $LOCAL_IMAGE_PATH/image.img.xz to image partition $IMAGE_DEV"
unxz -v --stdout $LOCAL_IMAGE_PATH/image.img.xz | dd of=$IMAGE_DEV bs=100M

echo "Verifying FS at target partitions $BOOT_DEV"
fsck.vfat -a $BOOT_DEV || true
echo "Verifying FS at target partition $IMAGE_DEV"
# e2fsck will return error when fixing a corrupted FS, so need to suppress it
e2fsck -yf $IMAGE_DEV || true
echo "Resizing fs on image partition $IMAGE_DEV to all available space"
resize2fs $IMAGE_DEV
echo "Injecting installation images into FS on image partition"
IMAGE_PART_DIR=`mktemp -d`
mount $IMAGE_DEV $IMAGE_PART_DIR
cp $LOCAL_IMAGE_PATH/boot.img.xz $IMAGE_PART_DIR/
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
