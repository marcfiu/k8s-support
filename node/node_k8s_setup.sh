#!/bin/bash

exec 2> /tmp/k8s_setup.log 1>&2
set -euxo pipefail

# This should be the final step. Prior to this script running, we should have
# made sure that the disk is partitioned appropriately and mounted in the right
# places (one place to serve as a cache for Docker images, the other two to
# serve as repositories for core system data and experiment data, respectively)

# Save the arguments
# IPV4="$1"  # Currently unused.
HOSTNAME="$2"

# Turn the hostname into its component parts.
MACHINE=$(echo "${HOSTNAME}" | tr . ' ' | awk '{ print $1 }')
SITE=$(echo "${HOSTNAME}" | tr . ' ' | awk '{ print $2 }')
METRO="${SITE/[0-9]*/}"

# Make sure to download any and all necessary auth tokens prior to this point.
# It should be a simple wget from the master node to make that happen.
#
# TODO: This name should probably be parameterized.  When we do that work, we
# will likely want to make sure that the kernel argument epoxy.project is passed
# in on the command line.
MASTER_NODE=k8s-platform-master.mlab-sandbox.measurementlab.net

# TODO(https://github.com/m-lab/k8s-support/issues/29) This installation of
# things into etc should be done as part of cloud-config.yml or ignition or just
# something besides this script.
# Install things in /etc
# Startup configs for the kubelet
RELEASE=$(cat /usr/share/oem/installed_k8s_version.txt)
mkdir -p /etc/systemd/system
curl --silent --show-error --location "https://raw.githubusercontent.com/kubernetes/kubernetes/${RELEASE}/build/debs/kubelet.service" > /etc/systemd/system/kubelet.service

# Install all non-multus things into /opt/cni/bin
mkdir -p /opt/cni/bin
pushd /opt/cni/bin
  cp /usr/cni/bin/* .
  # Install multus into /opt/cni/bin
  wget -q https://storage.googleapis.com/k8s-platform-mlab-sandbox/bin/multus
  chmod +x multus
  # Install index_to_ip into /opt/cni/bin
  wget https://storage.googleapis.com/k8s-platform-mlab-sandbox/bin/index_to_ip
  chmod +x index_to_ip
popd
# Make all the fakes so that network plugins can be debugged
mkdir -p /opt/fakecni/bin
pushd /opt/fakecni/bin
  wget https://storage.googleapis.com/k8s-platform-mlab-sandbox/bin/fake.sh
  chmod +x fake.sh
  for i in /opt/cni/bin/*; do
    ln -s /opt/fakecni/bin/fake.sh /opt/fakecni/bin/$(basename "$i")
  done
popd

# Add node tags to the kubelet so that node metadata is there right at the very
# beginning, and make sure that the kubelet has the right directory for the cni
# plugins.
NODE_LABELS="mlab/machine=${MACHINE},mlab/site=${SITE},mlab/metro=${METRO},mlab/type=platform"
mkdir -p /etc/systemd/system/kubelet.service.d
curl --silent --show-error --location "https://raw.githubusercontent.com/kubernetes/kubernetes/${RELEASE}/build/debs/10-kubeadm.conf" \
  | sed -e "s|KUBELET_KUBECONFIG_ARGS=|KUBELET_KUBECONFIG_ARGS=--node-labels=$NODE_LABELS |g" \
  | sed -e 's|--cni-bin-dir=[^ "]*|--cni-bin-dir=/opt/fakecni/bin|' \
  > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

systemctl daemon-reload
systemctl enable docker
systemctl start docker
systemctl enable kubelet
systemctl start kubelet

TOKEN=$(curl "http://${MASTER_NODE}:8000" | grep token | awk '{print $2}' | sed -e 's/"//g')
export PATH=/sbin:/usr/sbin:/opt/bin:${PATH}
kubeadm join "${MASTER_NODE}:6443" \
  --token "${TOKEN}" \
  --discovery-token-ca-cert-hash sha256:5c01e2c5a48a1d896f580951e36765fb98212e298f56ee9002906953ff95bf4f
