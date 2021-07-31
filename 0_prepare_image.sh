#!/bin/bash

source ./init_settings.sh

echo "WARNING! ALL DATA WILL BE LOST ON $DEVICE!!!"
echo "Hit enter to flash $DEVICE with $IMAGE"
read

TEMP_DIR=`mktemp -d`
if [ ! -r images ] ; then
  echo "Directory 'images' does not exist yet, creating it now"
  mkdir images
fi

echo "Writing OS image $IMAGE to device $DEVICE"
dd if=$IMAGE of=$DEVICE status=progress

echo "Updating partition map in kernel memory"
partprobe $DEVICE

# damn, upgrading kernels and k8s stuff REALLY eats disk space
echo "Resizing image partition to +1500M"
IMAGE_PARTITION_END="`parted --machine ${DEVICEPART}2 unit MB print | tail -n 1 | awk -F':' {'print $3'} | sed 's/MB//g'`"
IMAGE_PARTITION_TARGET=$((IMAGE_PARTITION_END+1500))
parted --script -a opt $DEVICE resizepart 2 $IMAGE_PARTITION_TARGET
resize2fs ${DEVICEPART}2

echo "Creating working partitions at free space"
PARTED_OUTPUT="`parted --machine $DEVICE unit b print free`"
FREE_SPACE_START=`echo "$PARTED_OUTPUT" | tail -n 1 | awk -F':' {'print $2'}`
DISK_END="`parted --machine ${DEVICE} unit MB print | grep $DEVICE | awk -F':' {'print $2'} | sed 's/MB//g'`"

echo "Setting disk layout for k8s node"
echo "Creating ext4 partition on $DEVICE start $FREE_SPACE_START end $DISK_END"
parted --script -a opt $DEVICE mkpart primary ext4 $FREE_SPACE_START 100%
echo "Dumping layout to images/node.partitions"
dd if=$DEVICE of=images/node.partitions bs=512 count=1

echo "Updating partition map in kernel memory"
partprobe $DEVICE

echo "Setting disk layout for k8s master"
parted $DEVICE rm 3
WORKING_PARTITION_END=$((DISK_END-1000))
MASTER_PARTITION_START=$((DISK_END-999))
echo "Creating working partition on $DEVICE start $FREE_SPACE_START end $WORKING_PARTITION_END"
parted --script -a opt $DEVICE mkpart primary ext4 $FREE_SPACE_START $WORKING_PARTITION_END
echo "Creating master partition on $DEVICE start $MASTER_PARTITION_START end $DISK_END"
parted --script -a opt $DEVICE mkpart primary ext4 $MASTER_PARTITION_START 100%
echo "Dumping layout to images/master.partitions"
dd if=$DEVICE of=images/master.partitions bs=512 count=1

echo "Updating partition map in kernel memory"
partprobe $DEVICE

mount ${DEVICEPART}1 $TEMP_DIR
echo "Enabling memory cgroup on boot"
if  [ "`grep memory $TEMP_DIR/cmdline.txt`" = "" ] ; then
  sed -i 's/.*/&\ cgroup_enable=memory/g' $TEMP_DIR/cmdline.txt
fi
umount $TEMP_DIR

mount ${DEVICEPART}2 $TEMP_DIR
echo "Installing taskrunner to image"
mkdir $TEMP_DIR/usr/lib/k8r
cp variables.cfg $TEMP_DIR/usr/lib/k8r/
mkdir $TEMP_DIR/usr/lib/k8r/tasks
cp -f ./tasks/* $TEMP_DIR/usr/lib/k8r/tasks/
install -m 0755 task_runner.sh $TEMP_DIR/usr/local/bin/task_runner.sh
cp -f task_runner.service $TEMP_DIR/etc/systemd/system/
ln -sf /etc/systemd/system/task_runner.service $TEMP_DIR/etc/systemd/system/multi-user.target.wants/task_runner.service
mkdir $TEMP_DIR/var/spool/k8r/
mkdir $TEMP_DIR/var/spool/k8r/tasks
mkdir $TEMP_DIR/var/spool/k8r/immediate_jobs
echo "Making the system send plain mac as identifier to avoid unique dhcp ids"
echo "when reinstalling OS on the same node."
echo DUIDType=link-layer >> $TEMP_DIR/etc/systemd/networkd.conf
sync
umount $TEMP_DIR
rmdir $TEMP_DIR

echo "======================================================================="
echo "Completed!"
echo "Please insert this sdcard into your rasbperry device, and run command"
echo
echo 'sudo bash /usr/lib/k8r/tasks/bootstrap_image.sh'
echo
echo "to configure node image."
echo "When done, plug your sdcard back into your flashing device and proceed"
echo "with a next step."
