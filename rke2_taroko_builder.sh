#!/bin/bash


RED='\033[1;31m' # alarm
GRN='\033[1;32m' # notice
YEL='\033[1;33m' # warning
NC='\033[0m' # No Color

# function
# debug mode
Debug() {
  ### output log
  [[ -f /tmp/pve_execute_command.log ]] && rm /tmp/rke2_execute_command.log
  exec {BASH_XTRACEFD}>> /tmp/rke2_execute_command.log
  set -x
  #set -o pipefail
}


# check environment
check_env() {
  clear
  printf "${GRN}[Stage: Check Environment]${NC}\n"
  [[ ! -f ./setenvVar ]] && printf "${RED}setenvVar file not found${NC}\n" && exit 1
  var_names=$(cat setenvVar | grep -v '#' | cut -d " " -f 2 | cut -d "=" -f 1 | tr -s "\n" " " | sed 's/[ \t]*$//g')
  for var_name in ${var_names[@]}
  do
    [ -z "${!var_name}" ] && printf "${RED}$var_name is unset.${NC}\n" && exit 1
  done

  ### check vm ip
  for c in ${NODE_IP[@]}
  do
    ip=$(echo $c | cut -d ':' -f2)
    ping -c 1 -W 1 $ip &>/dev/null
    if [[ "$?" != "0" ]]; then
      printf "${RED}=====$ip Fail=====${NC}\n" && exit 1
    fi
  done

  ### check ssh login to Rke2 node without password
  for n in ${NODE_IP[@]}
  do
    ip=$(echo $n | cut -d ':' -f2)
    ssh -q -o BatchMode=yes -o "StrictHostKeyChecking no" root@"$ip" '/bin/true' &> /dev/null
    if [[ "$?" != "0" ]]; then
      printf "${RED}Must be configured to use ssh to login to the Rke2 node without a password.${NC}\n"
      printf "${YEL}=====Run this command: ssh-keygen -t rsa -P ''=====${NC}\n"
      printf "${YEL}=====Run this command: ssh-copy-id root@"$ip"=====${NC}\n"
      exit 1
    fi
    ssh -q -o BatchMode=yes -o "StrictHostKeyChecking no" bigred@"$ip" '/bin/true'
    if [[ "$?" != "0" ]]; then
      printf "${RED}Must be configured to use ssh to login to the Rke2 node without a password.${NC}\n"
      printf "${YEL}=====Run this command: ssh-keygen -t rsa -P ''=====${NC}\n"
      printf "${YEL}=====Run this command: ssh-copy-id bigred@"$ip"=====${NC}\n"
      exit 1
    fi
  done
}

# install rke2 master
inrke2_master() {
  printf "${GRN}[Stage: Create Rke2 Master]${NC}\n"
  masterip=$(echo ${NODE_IP[0]} | cut -d ':' -f2)

  ssh root@"$masterip" mkdir -p /etc/rancher/rke2/ &>> /tmp/rke2_taroko_builder.log
  scp config_m1.yaml root@"$masterip":/etc/rancher/rke2/config.yaml &>> /tmp/rke2_taroko_builder.log

  ssh bigred@"$masterip" /bin/bash << EOF &>> /tmp/rke2_taroko_builder.log
    curl -sfL https://get.rke2.io --output install.sh
    chmod +x install.sh
    sudo INSTALL_RKE2_CHANNEL="$RKE2_K8S_VERSION" ./install.sh
    export PATH=$PATH:/opt/rke2/bin
    sudo systemctl enable --now rke2-server
    mkdir $HOME/.kube
    sudo cp /etc/rancher/rke2/rke2.yaml .kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    sudo cp /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/
    sudo cp /opt/rke2/bin/* /usr/local/bin/
EOF
  kubectl wait node m1 --for=condition=Ready --timeout=300s
}

# install rke2 worker
inrke2_worker() {
  printf "${GRN}[Stage: Create Rke2 Worker]${NC}\n"
  masterip=$(echo ${NODE_IP[0]} | cut -d ':' -f2)
  w1ip=$(echo ${NODE_IP[1]} | cut -d ':' -f2)
  w2ip=$(echo ${NODE_IP[2]} | cut -d ':' -f2)

  ssh root@"$w1ip" mkdir -p /etc/rancher/rke2/ &>> /tmp/rke2_taroko_builder.log
  sed -i "s/masterip/$masterip/g" config_w1.yaml
  scp config_w1.yaml root@"$w1ip":/etc/rancher/rke2/config.yaml &>> /tmp/rke2_taroko_builder.log

  ssh root@"$w2ip" mkdir -p /etc/rancher/rke2/ &>> /tmp/rke2_taroko_builder.log
  sed -i "s/masterip/$masterip/g" config_w2.yaml
  scp config_w2.yaml root@"$w2ip":/etc/rancher/rke2/config.yaml &>> /tmp/rke2_taroko_builder.log

  ssh bigred@"$w1ip" /bin/bash << EOF &>> /tmp/rke2_taroko_builder.log
    curl -sfL https://get.rke2.io --output install.sh
    chmod +x install.sh
    sudo INSTALL_RKE2_CHANNEL="$RKE2_K8S_VERSION" INSTALL_RKE2_TYPE="agent" ./install.sh
    export PATH=$PATH:/opt/rke2/bin
    sudo systemctl enable --now rke2-agent.service
    sudo cp /opt/rke2/bin/* /usr/local/bin/
EOF
  kubectl wait node w1 --for=condition=Ready --timeout=300s

  ssh bigred@"$w2ip" /bin/bash << EOF &>> /tmp/rke2_taroko_builder.log
    curl -sfL https://get.rke2.io --output install.sh
    chmod +x install.sh
    sudo INSTALL_RKE2_CHANNEL="$RKE2_K8S_VERSION" INSTALL_RKE2_TYPE="agent" ./install.sh
    export PATH=$PATH:/opt/rke2/bin
    sudo systemctl enable --now rke2-agent.service
    sudo cp /opt/rke2/bin/* /usr/local/bin/
EOF
  kubectl wait node w2 --for=condition=Ready --timeout=300s
}


taroko() {
printf "${GRN}[Stage: Deploy Taroko]${NC}\n"
masterip=$(echo ${NODE_IP[0]} | cut -d ':' -f2)
w1ip=$(echo ${NODE_IP[1]} | cut -d ':' -f2)
w2ip=$(echo ${NODE_IP[2]} | cut -d ':' -f2)

# install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml &>/dev/null
kubectl apply -f wulin/wkload/mlb/kube-mlb-config.yaml &>/dev/null
kubectl wait -n metallb-system pod -l component=controller --for=condition=Ready --timeout=180s

# install local-path-provisioner
wget -O - https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.22/deploy/local-path-storage.yaml | kubectl apply -f -
kubectl wait -n local-path-storage pod -l app=local-path-provisioner --for=condition=Ready --timeout=180s

# install minio & minio client
kubectl create ns s3-system
kubectl apply -f wulin/wkload/minio/snsd/miniosnsd.yaml &>/dev/null
kubectl wait -n s3-system pod -l app=miniosnsd --for=condition=Ready --timeout=180s
sleep 5; [[ "$?" != "0" ]] && echo "Deploy Minio Failed!" && exit 1
which mc &>/dev/null
if [ "$?" != "0" ]; then
   sudo curl -s https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/bin/mc
   [ "$?" == "0" ] && sudo chmod +x /usr/bin/mc && echo "mc client download ok"
fi
mc config host add mios http://172.22.1.150:9000 minio minio123 &>/dev/null
[[ "$?" != "0" ]] && echo "Add Mios http://172.22.1.150:9000 Failed!" && exit 1
mc mb mios/kadm &>/dev/null
mc cp -r wulin/* mios/kadm/ &>/dev/null
[ "$?" == "0" ] && echo "wulin to mios/kadm ok"


# install redis
kubectl apply -f wulin/wkload/redis/pvc-redis.yaml &>/dev/null
kubectl apply -f wulin/wkload/redis/dep-redis.yaml &>/dev/null
kubectl apply -f wulin/wkload/redis/svc-redis.yaml &>/dev/null
kubectl wait -n s3-system pod -l app=redis --for=condition=Ready --timeout=180s

# install JuiceFS
wget -qO - https://raw.githubusercontent.com/juicedata/juicefs-csi-driver/master/deploy/k8s.yaml | \
sed 's|juicedata/juicefs-csi-driver|quay.io/flysangel/juicedata/juicefs-csi-driver|g' | \
sed 's|juicedata/csi-dashboard|quay.io/flysangel/juicedata/csi-dashboard|g' | \
sed 's|namespace: kube-system|namespace: s3-system|g' | \
sed -E 's|replicas: [0-9]|replicas: 1|g' | \
kubectl apply -f - &>/dev/null

kubectl wait -n s3-system pod -l app=juicefs-csi-controller --for=condition=Ready --timeout=360s
kubectl apply -f wulin/wkload/juicefs/sc-juicefs.yaml &>/dev/null

# install kadm
kubectl apply -f wulin/wkload/kadm/kube-kadm-dkreg.yaml &>/dev/null
kubectl wait -n kube-system pod -l app=kadm --for=condition=Ready --timeout=360s
kubectl exec kube-kadm -n kube-system -c kadm -- mkdir -p /home/bigred/wulin/{bin,yaml}
kubectl cp wulin/wkload/kadm/system.sh kube-system/kube-kadm:/home/bigred/wulin/bin/system.sh -c kadm
kubectl exec kube-kadm -n kube-system -c kadm -- sudo chown bigred:wheel -R /home/bigred/ &>/dev/null

# add dkreg.kube-system to /etc/hosts
dip=$(kubectl get svc -n kube-system | grep dkreg | tr -s ' ' | cut -d ' ' -f3)
ssh bigred@"$masterip" "echo "$dip dkreg.kube-system" | sudo tee -a /etc/hosts &>/dev/null"
ssh bigred@"$w1ip" "echo "$dip dkreg.kube-system" | sudo tee -a /etc/hosts &>/dev/null"
ssh bigred@"$w2ip" "echo "$dip dkreg.kube-system" | sudo tee -a /etc/hosts &>/dev/null"

printf "${GRN}[take office]${NC}\n"
}

if [[ "$#" < 1 ]]; then
else
  case $1 in
  create)
    Debug
    source ./setenvVar
    [[ -f /tmp/pve_vm_manager.log ]] && rm /tmp/pve_vm_manager.log
    check_env
    inrke2_master
    inrke2_worker
    kubectl label node m1 kadm=node
    kubectl label node w1 node-role.kubernetes.io/worker=
    kubectl label node w2 node-role.kubernetes.io/worker=
    taroko
    ;;
  *)
      help
    ;;
  esac
fi
