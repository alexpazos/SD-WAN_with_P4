#########################################################################
#  vnf-CPE (site1 / site2) – versión actualizada                       #
#########################################################################

resource "kubernetes_pod" "vnf_cpe" {
  for_each = local.vnf_cpe_instances   # site1 y site2

  metadata {
    name      = "vnf-cpe-${each.key}"
    namespace = "rdsv"

    labels = {
      "k8s-app" = "vnf-cpe-${each.key}"
    }

    annotations = {
  "k8s.v1.cni.cncf.io/networks" = jsonencode([
    {
      name      = "extnet${each.value.netnum}"    
      interface = "net${each.value.netnum}"        
    }
  ])
}
}

  spec {
    container {
      name  = "vnf-cpe"
      image = "educaredes/vnf-cpe"
      command = [
        "/bin/sh", "-c",
        <<-EOT
          set -e -x
          /usr/share/openvswitch/scripts/ovs-ctl start
          while [ ! -e /var/run/openvswitch/db.sock ]; do echo '...Esperando OVS…'; sleep 1; done

          ################################ [1] Resolver ACCESS
          while true; do
            ACCESS_IP=$(getent hosts ${each.value.access_service_name} | awk '{print $1}')
            [ -n "$ACCESS_IP" ] && break
            echo '...Esperando IP de vnf-access…'; sleep 2
          done
          echo "CPE $(hostname -i) → access $ACCESS_IP"

          ################################ BRINT  (access ↔ cpe)
          # 1. Crear bridge OVS dentro del contenedor CPE
          ovs-vsctl add-br brint

          # 2. Asignar IP interna al bridge (LAN cliente)
          ifconfig brint 192.168.255.254/24

          # 3. Crear túnel VXLAN ID 4 hacia KNF:Access
          ip link add axscpe type vxlan id 4 remote $ACCESS_IP dstport 8742 dev eth0 || true
          ovs-vsctl add-port brint axscpe
          ifconfig axscpe up

          # 4. Ajustar MTU para evitar fragmentación VXLAN
          ifconfig brint mtu 1400

          # 5. Asignar IP pública al vCPE (interfaz netX)
          ifconfig net${each.value.netnum} ${each.value.vcpepubip}/24

          # 6. Rutas para poder alcanzar primero al Pod Access
          ip route add $ACCESS_IP/32 via 169.254.1.1

          # 7. Ahora modificamos la ruta por defecto
          ip route del 0.0.0.0/0 via 169.254.1.1
          ip route add 0.0.0.0/0 via ${each.value.vcpegw}

          # 8. Ruta hacia la subred privada del cliente
          ip route add ${each.value.custprefix} via 192.168.255.253

          ################################  Interfaz pública + NAT
          /vnx_config_nat brint net${each.value.netnum}

          ################################ [4] BRWAN   (cpe ↔ wan)
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
          # WAN_IP ya está resuelto. Sólo queda crear el bridge y túneles.
          ip route add $WAN_IP/32 via 169.254.1.1
          ovs-vsctl add-br brwan
          ifconfig brwan mtu 1400          
          ifconfig brwan up  

          # 1. Crear túnel VXLAN ID 5 hacia vnf:wan              
          ip link add cpewan type vxlan id 5 remote $WAN_IP dstport 8741 dev eth0
          ovs-vsctl add-port brwan cpewan
          ifconfig cpewan up

          # VXLAN entre sites (sr1 ↔ sr2)
          ip link add sr1sr2 type vxlan id 12 remote ${each.value.remotesite} dstport 8742 dev net${each.value.netnum}
          ovs-vsctl add-port brwan sr1sr2
          ifconfig sr1sr2 up


          
       
        #  OpenFlow hacia KNF:ctrl 

          ovs-vsctl set bridge brwan protocols=OpenFlow10,OpenFlow12,OpenFlow13
          ovs-vsctl set-fail-mode brwan secure
          ovs-vsctl set bridge brwan other-config:datapath-id=0000000000000002
                                                
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
        capabilities { add = ["NET_ADMIN", "SYS_ADMIN"] }
      }
    }
  }
}

#########################################################################
#  Servicio headless para descubrir la IP del CPE                       #
#########################################################################

resource "kubernetes_service" "vnf_cpe" {
  for_each = local.vnf_cpe_instances

  metadata {
    name      = "vnf-cpe-service-${each.key}"
    namespace = "rdsv"
  }

  spec {
    cluster_ip = "None"
    selector   = { "k8s-app" = "vnf-cpe-${each.key}" }
  }
}