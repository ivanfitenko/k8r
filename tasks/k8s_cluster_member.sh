#!/bin/bash

source /usr/lib/k8r/variables.cfg

DEVPATH=`blkid | grep system-boot | awk -F: {'print $1'} | sed 's/[0-9]*$//g'`

MASTER_PARTITION=`blkid | grep ${DEVPATH}4`

# Set hostname from IP of an interface having an external route, replacing dots
# with dashes.
NEWHOSTNAME=`ip route get 8.8.8.8 | head -n1 | grep -Eo '([0-9]*\.){3}[0-9]*' \
             | tail -n1 | tr . - `
while [ "$NEWHOSTNAME" = "" ] ; do
  echo "No hostname yet, sleeping for 10 seconds before retry"
  sleep 10
  NEWHOSTNAME=`ip route get 8.8.8.8 | head -n1 \
          | grep -Eo '([0-9]*\.){3}[0-9]*' | tail -n1 | tr . - `
done
echo "Setting hostname to $NEWHOSTNAME"
hostname $NEWHOSTNAME
echo $NEWHOSTNAME > /etc/hostname


if [ "$MASTER_PARTITION" != "" ] ; then
  echo "Found partition for master node persistent data. Bootstrapping master."
  # Let's save some time. Run this job directly and immediately instead of 
  # scheduling it for the next minute
  bash /usr/lib/k8r/tasks/bootstrap_master.sh
  echo "Scheduling reboot via post-run task"
  cp -f /usr/lib/k8r/tasks/reboot.sh /var/spool/k8r/immediate_jobs/
elif [ "$KUBEADM_JOIN_STRING" != "" ] ; then
  echo "Joining k8s cluster as node"
  bash -c "$KUBEADM_JOIN_STRING"
else
  echo "ERROR: no master partition found and KUBEADM_JOIN_STRING not set. Cannot join cluster. Remove this line from /etc/motd when fixed" | tee -a /etc/motd
fi
