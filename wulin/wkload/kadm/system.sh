export POD_NAMESPACE=default
export KUBERNETES_SERVICE_PORT=443
export KUBERNETES_SERVICE_HOST=kubernetes.default
export KUBERNETES_SERVICE_PORT_HTTPS=443
#export TALOSCONFIG=/home/bigred/wulin/talosconfig
export NOW="--force --grace-period 0"
export PS1='\u@\h:\w$ '
export KUBE_EDITOR="nano"

alias kg='kubectl get'
alias ka='kubectl apply'
alias kd='kubectl delete'
alias kt='kubectl top'
alias ks='kubectl get all -n kube-system'
alias kt='kubectl top'
alias kk='kubectl krew'
alias kp="kubectl get pods -o wide -A | sed 's/(.*)//' | tr -s ' ' | cut -d ' ' -f 1-4,7,8 | column -t"
alias dkimg='curl -X GET -s -u bigred:bigred http://dkreg.kube-system:5000/v2/_catalog | jq ".repositories[]"'
alias kgip="kubectl get pod --template '{{.status.podIP}}'"
alias pingdup='sudo arping -D -I eth0 -c 2 '
alias ping='ping -c 4'
alias dir='ls -alh'
alias docker='sudo /usr/bin/podman'

if [ "$USER" == "bigred" ]; then
   sudo mount --make-rshared /

   if [ ! -d /home/bigred/.krew ]; then
      kubectl krew install directpv &>/dev/null
      [ "$?" == "0" ] && echo "kubectl directpv ok"
   fi

   mc config host ls | grep mios &>/dev/null
   if [ "$?" != "0" ]; then
      mc config host add mios http://miniosnsd.s3-system:9000 minio minio123 &>/dev/null
      [ "$?" == "0" ] && echo "mios ok"
   fi

   kubectl delete pod -A --field-selector=status.phase==Succeeded | grep 'No resources found' &>/dev/null
   [ "$?" != "0" ] && echo "delete all completed pods"

   kubectl delete pod -A --field-selector=status.phase==Failed | grep 'No resources found' &>/dev/null
   [ "$?" != "0" ] && echo "delete all errored pods"
   echo ""

   kubectl describe sa default | grep dkreg &>/dev/null
   if [ "$?" != "0" ]; then
     # create dkreg secret (default namespace)
     sudo podman login --tls-verify=false -u bigred -p bigred dkreg.kube-system:5000 &>/dev/null
     sudo cp /run/containers/0/auth.json /home/bigred/auth.json; sudo chmod 755 /home/bigred/auth.json
     sudo podman logout dkreg.kube-system:5000 &>/dev/null
     kubectl create secret generic dkreg -n default --from-file=.dockerconfigjson=/home/bigred/auth.json --type=kubernetes.io/dockerconfigjson &>/dev/null
     kubectl patch serviceaccount default -n default -p '{"imagePullSecrets": [{"name": "dkreg"}]}' &>/dev/null
     echo "dkreg secret ok"
   fi
   
fi

export PATH=/home/bigred/wulin/wkload/usdt/bin:$PATH
[ ! -d "$USER/wulin" ] && mkdir -p "$USER/wulin/yaml"
