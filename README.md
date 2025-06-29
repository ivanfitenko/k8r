# k8r - Kubernetes cluster on Raspberry Pi

## TL;DR
Configure a few settings like k8s version, run build script, flash the build
image to your Raspberry PI, and you have master node running. Repeat for nodes
(just change one setting before re-building). Scale, upgrade and rebuild in
just a few commands.

## About

K8R stands for "Kubernetes on Raspberry Pi". The aim of the project is to provide
an IaaS-like (Infrastructure as a Service) experience for deploying, upgrading,
and managing K8s clusters. Rather than manually installing and configuring the
software on nodes, both master and worker nodes are deployed by writing a
pre-built "golden image" onto their disks. To upgrade the nodes, create a new
image for the updated version of Kubernetes, upload it to the nodes (or utilize
the built-in feature for downloading images via HTTP), and execute the upgrade 
script. Should a node encounter corruption or malfunction, it can be easily 
reinitialized to its initial state with just a single command.


## Requirements

### Build Platform
- Linux or MacOS on arm64 or x86_64
- docker
- 15G free space to contain initial, intermediate, and final images

### Nodes
- Raspberri Pi 4b
- At least 16G SD card


## Installation
### Configuation
Download a bootable Ubuntu image to be used as a base image for nodes. Latest
LTS build for Raspberry Pi is the primary testing target here, so it shoud work
best.

Write your build configuration to variables.cfg file. Use variables.cfg.example
file and "Settings" section for referrence. Minimum required settings are IMAGE
and K8S_VERSION.

While these two will allow you to build an image "just to give it a try", there
is at least one more thing to configure if you plan to use your cluster for
longer period of time. The cluster's certificates include IP address of master
node as CN field, and can also contain an additional domain name. In case if
address of master node changes, you might have to rebuild all the cluster certs
and re-join the nodes. So it is strongly recommended that you create a static
IP-to-MAC bidning in your DHCP server, and/or create a DNS name for your master
node, and configure CONTROL_PLANE_ENDPOINT variable with this name.

More useful settings to improve the cluster maintainability, like setting a
non-default password for login user, can be found under "Settings" section.

### Bootstrapping master node
After you configured your variables.cfg, it is time to bootstrap your master
node as the fist node in your cluster. If you are reusing variables.cfg from 
another cluster, make sure that KUBEADM_JOIN_STRING is absent or set to empty.

This is what tells the scripts that this is the first boot, and the SD card
has to be partitioned for master-style layout, i.e. it should have an additional
partition for master data.

Build the image with
```
bash ./build.sh
```

Check the logs to make sure that all went well. There will be some errors caused
by building it in docker+chroot - these will be followed by a message that the
error can be safely ignored. Errors that do not have an explanation coming right
after them may be a sign of a broken build. Please report them, or, even better,
open a PR with a fix. Builds having such errors should not be used to update or
install the nodes unless you know what you do.

After a successful build, an image at `images/bootable_image.img` is ready to
be flashed on an SD card and used to boot your master node.
Bootup and initialization would take 5-15 minutes depending on the speed of
your SD card and internet connection (you will be downloading images for control
panel).

After successfull boot, you will be able to log in to your new master node with
the default user for your distriution (most likely "ubuntu"), and the default
password (usually ubuntu), or your custom password if you set it.

Check /var/log/kubeadm.log to make sure the installation went well and grab the
admin context from /etd/kubernetes/admin.conf.

A command to join new nodes to the cluster is stored at /usr/lib/k8r/join_string
Update your variables.cfg file and set this command as a value of parameter
KUBEADM_JOIN_STRING.

### Adding worker nodes
With KUBEADM_JOIN_STRING in variables.cfg file set to the value from previous
step, re-run the build process by executing 
bash ./build.sh

This will build the image again with the new variables file (just injecting it
is not implemented yet), creating a new images/bootable_image.img which you can
use for initial bootstrap of the worker nodes, along with two more files,
`images/boot.tar.xz` and `images/image.img.xz` which can be used to upgrade, as
well as to downgrade the nodes.

Now you can write bootable-image.img to SD cards of as many new nodes as you
need, boot them, and have them joined your new cluster. Enjoy! :-)

## Upgrading

Nodes can be upgraded in two ways: by copying updated images directly to the
nodes, of by having the nodes download the updated image from HTTP location.

To upgrade the nodes using local images, transfer updated  images/boot.tar.xz
and images/image.img.xz so some location on the node, and write it to image
partition with `update_image_partition.sh` script from `/usr/lib/k8r/tasks`
directory, passing a directory where the images can be found as a parameter.

For example, if image.img.xz (boot.tar.xz should be stored under the same
location) can be found at `/home/ubuntu/new_images/image.img.xz` on the target
node, then the command would look like this:
```
bash /usr/lib/k8r/tasks/update_image_partition.sh /home/ubuntu/new_images/
```

To upgrade the node from images from an HTTP, location, you need to have a
variable HTTP_IMAGE_URL set to proper location in your `variables.cfg` file.

This can be preconfigured during the build step, and you can change it or set
it on the target node anytime by editing `/usr/lib/k8s/variables.cfg` file.
As an example, if you have your image.img.xz (same for boot.tar.xz) available
at http://example.com/my_images/image.img.xz, then the setting should say
```
HTTP_IMAGE_URL="http://example.com/my_images/image.img.xz"
```
With this setting in place, just run 
```
bash /usr/lib/k8r/tasks/update_image_partition.sh
```
without any parameters. The images will be downloaded and unpacked into node's
boot and image partitions.

Finally, run a script to reboot the node into image partition and rewrite the
working partition with the updated image:
```
bash /usr/lib/k8r/tasks/set_reinstall_mode.sh
```
The node will reboot, start the OS from image partition, rewrite the working
partition with the new image, then boot again into working partition and either
update the master node and control panel to new versions, or re-join the updated
worker node to the cluster, depending on the node type.

## Refreshing/wiping the nodes

At some point, a node may become unstable or just utterly broken. Just like it 
can be done when using cloud providers, such nodes can be replaced by rebuilding
from a "golden" image which was used to bootstrap the nodes.

Similar to update operation, run a script to reboot the node into image 
partition and rewrite the working partition with the updated image:
```
bash /usr/lib/k8r/tasks/set_reinstall_mode.sh
```
The node will reboot, start the OS from image partition, rewrite the working
partition with the new image, then boot again into working partition and either
update the master node and control panel to new versions, or re-join the updated
worker node to the cluster, depending on the node type.

## Settings

`IMAGE` - Filename of original vendor's OS image to be used for all the nodes.
MUST be present under current directory. Must be an uncompressed image.

`K8S_VERSION` - K8S version to use in format of 1.2.3 (no 'v' prefix)

`CONTROL_PLANE_ENDPOINT` - DNS name or at a fixed IP-address pre-allocated for
your master node. Used for certificate chains, for nodes to join the cluster,
and more.

`TOKEN_TTL` - TTL of kubeadm's bootstrap token used by nodes to initially join
the cluster. Set to 0 to never expire. Example: `TOKEN_TTL="24h0m0s"`. Default is
`0` (never expire)

`POD_NETWORK_CIDR` - IP prefix for all pods in the Kubernetes cluster. This range
should not overlap with other prefixes on your local network.

`CNI_TYPE` - CNI to use, "calico", "weave" of "flannel". Only calico seems to
work out of the box for all uses. Flannel has issues that have not been resolved
yet and might not work for you. Weave net has changed its installation process
and is therefore broken now.

`CALICO_VERSION` - Use specific calico version (no "v" prefix). By default, 
v3.25.1 is used if the variable is not set.

`KUBEADM_JOIN_STRING` - A command for the nodes to join master. When a master 
node is bootstrapped, it will be written to file `/usr/lib/k8r/join_string`.
You need to put this value here before building an image for worker nodes.

`HTTP_IMAGE_URL` - URL prefix under which both image.img.xz and boot.tar.xz can
be found. For example, if you uploaded your files in a way that boot.tar.xz can
be downloaded from http://example.com/k8r/images/1.29.3/boot.tar.xz, then this 
setting would be "http://example.com/k8r/images/1.29.3/"

## Files and locations

### Local (build host):

`variables.cfg`: configure your K8R settings here. This file will be baked into
the built image and read by scripts.
`password_hash`:  to use your own password instead of default
"ubuntu", provide sha-512 hash of your password (or just copy it from 
/etc/shadow) in this file

### Nodes:
`/etc/systemd/system/task_runner.service` - systemd service for task_runner
`/usr/local/bin/task_runner.sh` - a service to start scheduled mainenance tasks
for k8r

`/var/spool/k8r/` : location for temporary files, locks and so on.

`/usr/lib/k8r/variables.cfg`: copy of build configuration for this image. Used by
various scripts

`/usr/lib/k8s/tasks/` : maintenance scripts, as below:

##### Intended for use by an operator:
`update_image_partition.sh`: write K8S image files to image partition. If ran
without parameters, will try to download an image from HTTP_IMAGE_URL. To use
an image from a local FS, use directory path as a parameter. The directory must
contain both image.img.xz and boot.tar.xz files.

`set_reinstall_mode.sh` - restart and reinstall the node. Boot and root
filesystems will be rewritten using an initial image, resulting in a fresh node.

#### NOT intended for use by an operator:
`install-docker.sh`: convenience script to install docker into build containers.
Runs on build host.

`bootstrap_image.sh`: runs basic software installation and configuration during
build process. Runs on build host.

`setup_partitions.sh`: creates required partitions inside image file. Runs on
build host.

`reboot.sh`: utility wrapper used by task_runner's scripts to reboot the node.

`setup_node.sh`: run minimal preparations on the node during install process and
trigger an appropriate next phase

`bootstrap_master.sh`: if node is expected to be a master, configure and start
k8s control plane


