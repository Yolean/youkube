#!/bin/bash
set -e

NODE_IP=$1
[ -z "$NODE_IP" ] && echo "First argument must be the node IP"

CLUSTER_TOKEN=$2
[ -z "$CLUSTER_TOKEN" ] && echo "Second argument must be the cluster init/join token"

### Try to align networking with k8s + flannel assumptions

getent hosts $NODE_IP | grep $NODE_IP | grep $HOSTNAME || {
  echo "Failed to match IP $NODE_IP to hostname $HOSTNAME"
  exit 1
}

NODE_IP_START=${NODE_IP:0:-1}
echo "${NODE_IP_START}1   kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local" >> /etc/hosts
for N in 1 2 3 4 5 6 7 8 9; do
  echo "${NODE_IP_START}$N   youkube-0$N" >> /etc/hosts
done

set -x
ip addr
ip route
# kubernetes migth make assumptions on interface based on default route
#ip route replace default via 192.168.38.1 dev eth1
set +x

timedatectl

### The rest is basically https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
# (but with a fix for flannel to use eth1)

CNI_VERSION="v0.6.0"
mkdir -p /opt/cni/bin
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-amd64-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz

RELEASE="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
echo "Kubernetes release: $RELEASE"

mkdir -p /opt/bin
cd /opt/bin
curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${RELEASE}/bin/linux/amd64/{kubeadm,kubelet,kubectl}
chmod +x {kubeadm,kubelet,kubectl}

curl -sSL "https://raw.githubusercontent.com/kubernetes/kubernetes/${RELEASE}/build/debs/kubelet.service" | sed "s:/usr/bin:/opt/bin:g" > /etc/systemd/system/kubelet.service
mkdir -p /etc/systemd/system/kubelet.service.d
curl -sSL "https://raw.githubusercontent.com/kubernetes/kubernetes/${RELEASE}/build/debs/10-kubeadm.conf" | sed "s:/usr/bin:/opt/bin:g" > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

systemctl enable kubelet && systemctl start kubelet

if [ "$NODE_IP" == "${NODE_IP_START}1" ]; then
  sed -i "s/#token#/$CLUSTER_TOKEN/" /vagrant/kubeadm-master.yml
  kubeadm init --config=/vagrant/kubeadm-master.yml
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl taint nodes --all node-role.kubernetes.io/master-
  FLANNEL_VERSION=v0.9.1
  curl -o /vagrant/kube-flannel.yml https://raw.githubusercontent.com/coreos/flannel/$FLANNEL_VERSION/Documentation/kube-flannel.yml
  # use the private interface, ideae from https://crondev.com/kubernetes-installation-kubeadm/
  sed -i.bak 's|"/opt/bin/flanneld",|"/opt/bin/flanneld", "--iface=eth1",|' /vagrant/kube-flannel.yml
  kubectl apply -f /vagrant/kube-flannel.yml
else
  # TODO get the actual join command from master, through /vagrant maybe if we can assume read-write shared folder
  #kubeadm join --token="$CLUSTER_TOKEN" kubernetes:6443 --discovery-token-ca-cert-hash sha256:...
  # For now "using token-based discovery without DiscoveryTokenCACertHashes can be unsafe"
  kubeadm join --token="$CLUSTER_TOKEN" kubernetes:6443 --discovery-token-unsafe-skip-ca-verification
fi
