#!/bin/bash

# damn, upgrading kernels and k8s stuff REALLY eats disk space
echo "Adding 1510M disk space to image to accomodate added packages"
dd if=/dev/zero bs=1510M count=1 >> images/bootable_image.img
losetup -c $DEVICE
echo "Resizing image partition to +1500M"
IMAGE_PARTITION_END="`parted --machine ${DEVICEPART}2 unit MB print | tail -n 1 | awk -F':' {'print $3'} | sed 's/MB//g'`"
IMAGE_PARTITION_TARGET=$((IMAGE_PARTITION_END+1500))
parted --script -a opt $DEVICE resizepart 2 $IMAGE_PARTITION_TARGET
echo "INFO: If running you are running in a docker container, it is safe to"
echo "ignore error messages above saying that kernel does not know about the"
echo "changes and asking to reboot."
resize2fs ${DEVICEPART}2

echo "Disabling vendor-provided user-data"
mount ${DEVICEPART}1 $K8R_IMAGE_MOUNT_DIR
mv $K8R_IMAGE_MOUNT_DIR/user-data $K8R_IMAGE_MOUNT_DIR/user-data.orig
echo "# Disabled by k8r build script. See user-data.orig for vendor-supplied file" > $K8R_IMAGE_MOUNT_DIR/user-data
umount $K8R_IMAGE_MOUNT_DIR

echo "Installing taskrunner to image"
mount ${DEVICEPART}2 $K8R_IMAGE_MOUNT_DIR
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

mount ${DEVICEPART}1 $K8R_IMAGE_MOUNT_DIR/boot
echo "Enabling memory cgroup on boot"
if  [ "`grep memory $K8R_IMAGE_MOUNT_DIR/boot/cmdline.txt`" = "" ] ; then
  sed -i 's/.*/&\ cgroup_enable=memory/g' $K8R_IMAGE_MOUNT_DIR/boot/cmdline.txt
fi

if [ "$K8R_IMAGE_MOUNT_DIR" = "" ] ; then
  echo "Umount and remove temporary mountpoint for image partitions"
  umount $K8R_IMAGE_MOUNT_DIR/boot
  umount $K8R_IMAGE_MOUNT_DIR
  rmdir $K8R_IMAGE_MOUNT_DIR
  if [ "`echo $DEVICE | grep 'loop'`" != "" ] ; then
    echo "Detaching image from loopback device $DEVICE"
    losetup -d $DEVICE
  fi
fi
