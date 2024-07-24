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
  done
}

# install rke2 master
inrke2_master() {
printf "${GRN}[Stage: Build Rke2 Master]${NC}\n"
masterip=$(echo ${NODE_IP[0]} | cut -d ':' -f2)

ssh root@"$masterip" mkdir -p /etc/rancher/rke2/ &>> /tmp/rke2_taroko_builder.log
scp config_m1.yaml root@"$masterip":/etc/rancher/rke2/config.yaml &>> /tmp/rke2_taroko_builder.log

ssh root@"$masterip" /bin/bash << EOF &>> /tmp/rke2_taroko_builder.log
  curl -sfL https://get.rke2.io --output install.sh
  chmod +x install.sh
  INSTALL_RKE2_CHANNEL="$RKE2_K8S_VERSION" ./install.sh
  export PATH=$PATH:/opt/rke2/bin
  systemctl enable --now rke2-server
  mkdir $HOME/.kube
  cp /etc/rancher/rke2/rke2.yaml .kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config
  cp /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/
  cp /opt/rke2/bin/* /usr/local/bin/
EOF
kubectl wait node m1 --for=condition=Ready --timeout=300s
}

# install rke2 worker
inrke2_worker() {
printf "${GRN}[Stage: Build Rke2 Worker]${NC}\n"
masterip=$(echo ${NODE_IP[0]} | cut -d ':' -f2)
w1ip=$(echo ${NODE_IP[1]} | cut -d ':' -f2)
w2ip=$(echo ${NODE_IP[2]} | cut -d ':' -f2)


ssh root@"$w1ip" mkdir -p /etc/rancher/rke2/ &>> /tmp/rke2_taroko_builder.log
sed -i "s/masterip/$masterip/g" config_w1.yaml
scp config_w1.yaml root@"$w1ip":/etc/rancher/rke2/config.yaml &>> /tmp/rke2_taroko_builder.log

ssh root@"$w2ip" mkdir -p /etc/rancher/rke2/ &>> /tmp/rke2_taroko_builder.log
sed -i "s/masterip/$masterip/g" config_w2.yaml
scp config_w2.yaml root@"$w2ip":/etc/rancher/rke2/config.yaml &>> /tmp/rke2_taroko_builder.log

ssh root@"$w1ip" /bin/bash << EOF &>> /tmp/rke2_taroko_builder.log
  curl -sfL https://get.rke2.io --output install.sh
  chmod +x install.sh
  INSTALL_RKE2_CHANNEL="$RKE2_K8S_VERSION" INSTALL_RKE2_TYPE="agent" ./install.sh
  export PATH=$PATH:/opt/rke2/bin
  systemctl enable --now rke2-agent.service
  cp /opt/rke2/bin/* /usr/local/bin/
EOF
kubectl wait node w1 --for=condition=Ready --timeout=300s

ssh root@"$w2ip" /bin/bash << EOF &>> /tmp/rke2_taroko_builder.log
  curl -sfL https://get.rke2.io --output install.sh
  chmod +x install.sh
  INSTALL_RKE2_CHANNEL="$RKE2_K8S_VERSION" INSTALL_RKE2_TYPE="agent" ./install.sh
  export PATH=$PATH:/opt/rke2/bin
  systemctl enable --now rke2-agent.service
  cp /opt/rke2/bin/* /usr/local/bin/
EOF
kubectl wait node w2 --for=condition=Ready --timeout=300s
}


taroko() {
printf "${GRN}[Stage: Deploy Taroko]${NC}\n"

# install minio & minio client
kubectl create ns s3-system
kubectl apply -f ~/wulin/wkload/minio/snsd/miniosnsd.yaml &>/dev/null
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
mc cp -r /home/bigred/wulin/* mios/kadm/ &>/dev/null
[ "$?" == "0" ] && echo "wulin to mios/kadm ok"

}

help() {
  cat <<EOF
Usage: rke2_taroko_builder.sh [OPTIONS]

Available options:

create        create rke2 cluster.
EOF
  exit
}

if [[ "$#" < 1 ]]; then
  help
else
  case $1 in
  create)
    Debug
    source ./setenvVar
    [[ -f /tmp/pve_vm_manager.log ]] && rm /tmp/pve_vm_manager.log
    check_env
    inrke2_master
    inrke2_worker
    kubectl label node w1 node-role.kubernetes.io/worker=
    kubectl label node w2 node-role.kubernetes.io/worker=
    ;;
  *)
      help
    ;;
  esac
fi
