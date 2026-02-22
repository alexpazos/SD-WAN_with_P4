provider "kubernetes" {
  config_path = "~/.kube/config"
}

resource "kubernetes_pod" "vnf_access" {
  for_each = local.vnf_access_instances   

  metadata {
    name      = "vnf-access-${each.key}"
    namespace = "rdsv"
    labels = {
      "k8s-app" = "vnf-access-${each.key}"
    }

    annotations = {
      "k8s.v1.cni.cncf.io/networks" = jsonencode([
        {
          name      = "accessnet${each.value.netnum}"
          interface = "net${each.value.netnum}"
        }
      ])
    }
  }


  spec {
    container {
      name  = "vnf-access"
      image = "educaredes/vnf-access"

     command = [
  "/bin/sh",
  "-c",
  <<-EOT
    set -e -x
    /usr/share/openvswitch/scripts/ovs-ctl start
    while [ ! -e /var/run/openvswitch/db.sock ]; do
      echo '...Esperando OVS...'
      sleep 1
    done

    while true; do
      CPE_IP=$(getent hosts ${each.value.cpe_service_name} | awk '{ print $1 }')
      if [ ! -z "$CPE_IP" ]; then break; fi
      echo "...Esperando IP de vnf-cpe..."
      sleep 2
    done

    SELF_IP=$(hostname -i)
    echo "IP local (access): $SELF_IP"
    echo "IP remota (cpe): $CPE_IP"

    ip link del vxlan2 2>/dev/null || true 
    ip link del axscpe 2>/dev/null || true 

    ovs-vsctl add-br brint
    ip link set brint up
    ifconfig net${each.value.netnum} ${each.value.vnftunip}/24

    # VXLAN al cliente
    ip link add vxlan2 type vxlan id 2 remote ${each.value.custunip} dstport 8742 dev net${each.value.netnum}

    # VXLAN al kNF:cpe
    ip link add axscpe type vxlan id 4 remote $CPE_IP dstport 8742 dev eth0

    ovs-vsctl add-port brint vxlan2
    ovs-vsctl add-port brint axscpe
    ip link set vxlan2 up
    ip link set axscpe up

    #########################################
    ###############  BRWAN  #################
    #########################################
    # Esperar IP del vnf-wan con backoff exponencial limitado
    SLEEP_TIME=2
    MAX_SLEEP=16

    while true; do
      WAN_IP=$(getent hosts vnf-wan-${each.key}-pod | awk '{print $1}')
      if [ ! -z "$WAN_IP" ]; then
        break
      fi
      echo "...Esperando IP de vnf-wan-${each.key}... durmiendo $SLEEP_TIME segundos"
      sleep $SLEEP_TIME
      # Duplicar tiempo de espera, pero no exceder MAX_SLEEP
      SLEEP_TIME=$(( SLEEP_TIME * 2 ))
      if [ $SLEEP_TIME -gt $MAX_SLEEP ]; then
        SLEEP_TIME=$MAX_SLEEP
      fi
    done

    ovs-vsctl add-br brwan

    # VXLAN al cliente
    ip link add vxlan1 type vxlan id 1 remote ${each.value.custunip} dstport 4789 dev net${each.value.netnum}

    # VXLAN al kNF:wan
    ip link add axswan type vxlan id 3 remote $WAN_IP dstport 4788 dev eth0

    ovs-vsctl add-port brwan vxlan1
    ovs-vsctl add-port brwan axswan

    ip link set vxlan1 up
    ip link set axswan up


  
        #  OpenFlow hacia KNF:ctrl 

          ovs-vsctl set bridge brwan protocols=OpenFlow10,OpenFlow12,OpenFlow13
          ovs-vsctl set-fail-mode brwan secure
          ovs-vsctl set bridge brwan other-config:datapath-id=0000000000000001
            
       CTRL_SVC="vnf-ctrl-${each.key}-service"

        CTRL_IP=$(getent hosts $CTRL_SVC | awk '{print $1}')
        until [ -n "$CTRL_IP" ]; do
          echo "Esperando IP de $CTRL_SVC"
          sleep 2
          CTRL_IP=$(getent hosts $CTRL_SVC | awk '{print $1}')
        done


          ovs-vsctl set-controller brwan tcp:$CTRL_IP:6633


          # Mantener el contenedor vivo
          sleep infinity
        EOT
     ] 



      security_context {
        privileged = true
        capabilities {
          add = ["NET_ADMIN", "SYS_ADMIN"]
        }
      }
    }
    }
  }

resource "kubernetes_service" "vnf_access" {
  for_each = local.vnf_access_instances

  metadata {
    name      = "vnf-access-${each.key}-service"
    namespace = "rdsv"
  }

  spec {
    cluster_ip = "None"
    selector = {
      "k8s-app" = "vnf-access-${each.key}"
 
  }
}
}

