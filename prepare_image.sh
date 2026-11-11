#!/bin/bash

# damn, upgrading kernels and k8s stuff REALLY eats disk space
echo "Adding 2010M disk space to image to accomodate added packages"
dd if=/dev/zero bs=2010M count=1 >> images/bootable_image.img
losetup -c $DEVICE
echo "Resizing image partition to +2000M"

IMAGE_PARTITION_END="`parted --machine ${DEVICEPART}2 unit MB print | tail -n 1 | awk -F':' {'print $3'} | sed 's/MB//g'`"
IMAGE_PARTITION_TARGET=$((IMAGE_PARTITION_END+2000))
parted --script -a opt $DEVICE resizepart 2 $IMAGE_PARTITION_TARGET
echo "INFO: If running you are running in a docker container, it is safe to"
echo "ignore error messages above saying that kernel does not know about the"
echo "changes and asking to reboot."
resize2fs ${DEVICEPART}2

echo "Mounting image root FS for changes"
mount ${DEVICEPART}2 $K8R_IMAGE_MOUNT_DIR
echo "Mounting EFI partition inside root FS"
# Somehow the mountpoint doesn't exist in root image. Maybe it gets created on
# first boot? Anyway, we need it to be mounted so that we can preserve the
# kernel updates.
if [ ! -r $K8R_IMAGE_MOUNT_DIR/boot/firmware ] ; then
  mkdir $K8R_IMAGE_MOUNT_DIR/boot/firmware
fi
mount ${DEVICEPART}1 $K8R_IMAGE_MOUNT_DIR/boot/firmware
echo "Disabling vendor-provided user-data"
mv $K8R_IMAGE_MOUNT_DIR/boot/firmware/user-data $K8R_IMAGE_MOUNT_DIR/boot/firmware/user-data.orig
echo "# Disabled by k8r build script. See user-data.orig for vendor-supplied file" > $K8R_IMAGE_MOUNT_DIR/boot/firmware/user-data
echo "Installing taskrunner to image"
mkdir $K8R_IMAGE_MOUNT_DIR/usr/lib/k8r
cp variables.cfg $K8R_IMAGE_MOUNT_DIR/usr/lib/k8r/
mkdir $K8R_IMAGE_MOUNT_DIR/usr/lib/k8r/tasks
cp -f ./tasks/* $K8R_IMAGE_MOUNT_DIR/usr/lib/k8r/tasks/
install -m 0755 task_runner.sh $K8R_IMAGE_MOUNT_DIR/usr/local/bin/task_runner.sh
cp -f task_runner.service $K8R_IMAGE_MOUNT_DIR/etc/systemd/system/
ln -sf /etc/systemd/system/task_runner.service $K8R_IMAGE_MOUNT_DIR/etc/systemd/system/multi-user.target.wants/task_runner.service
mkdir $K8R_IMAGE_MOUNT_DIR/var/spool/k8r/
mkdir $K8R_IMAGE_MOUNT_DIR/var/spool/k8r/tasks
mkdir $K8R_IMAGE_MOUNT_DIR/var/spool/k8r/immediate_jobs
echo "Making the system send plain mac as identifier to avoid unique dhcp ids"
echo "when reinstalling OS on the same node."
echo DUIDType=link-layer >> $K8R_IMAGE_MOUNT_DIR/etc/systemd/networkd.conf
sync
