# wan.tf – VNF WAN manifest (sin volumen de flujos JSON)

resource "kubernetes_pod" "vnf_wan" {
  for_each = local.vnf_wan_instances

  metadata {
    name      = "vnf-wan-${each.key}"
    namespace = "rdsv"
    labels = {
      "k8s-app" = "vnf-wan-${each.key}"
    }
    annotations = {
      "k8s.v1.cni.cncf.io/networks" = jsonencode([
        {
          name      = "mplswan"
          interface = "net1"
        }
      ])
    }
  }

  spec {
    container {
      name  = "vnf-wan"
      image = "educaredes/vnf-wan"

      # Se eliminó volume_mount porque las reglas SDN ya no se leen dentro del Pod

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

          # Esperar IP del servicio vnf-access
          while true; do
            ACCESS_IP=$(getent hosts vnf-access-${each.key}-service | awk '{print $1}')
            if [ -n "$ACCESS_IP" ]; then break; fi
            echo "...Esperando IP de vnf-access-${each.key}..."
            sleep 2
          done

          SELF_IP=$(hostname -i)
          echo "IP local (wan): $SELF_IP"
          echo "IP remota (access): $ACCESS_IP"


          ####################################################
          ####################### BRWAN ######################
          ####################################################

          ovs-vsctl add-br brwan

          # Crear túnel VXLAN ID 3 hacia vnf:access
          ip link del axswan 2>/dev/null || true
          ip link add axswan type vxlan id 3 remote $ACCESS_IP dstport 4788 dev eth0
          ovs-vsctl add-port brwan axswan
          ovs-vsctl add-port brwan net1

          ip link set axswan up
          ip route del $ACCESS_IP via 169.254.1.1 dev eth0 2>/dev/null || true
          ip route add $ACCESS_IP via 169.254.1.1 dev eth0

          ##########################
          ####### TÚNEL CPE ########
          ##########################
          # Esperar IP del CPE
          while true; do
            CPE_IP=$(getent hosts ${each.value.cpe_service_name} | awk '{ print $1 }')
            if [ -n "$CPE_IP" ]; then break; fi
            echo "...Esperando IP de vnf-cpe..."
            sleep 2
          done

          # Crear túnel VXLAN ID 5 hacia vnf:cpe 
          ip link del cpewan 2>/dev/null || true
          ip link add cpewan type vxlan id 5 remote $CPE_IP dstport 8741 dev eth0
          ovs-vsctl add-port brwan cpewan
          ifconfig cpewan up

          ###############################
          ####### OpenFlow y RYU ########
          ###############################

          ryu-manager /root/flowmanager/flowmanager.py ryu.app.ofctl_rest > /ryu.log 2>&1 &

          ovs-vsctl set bridge brwan protocols=OpenFlow10,OpenFlow12,OpenFlow13
          ovs-vsctl set-fail-mode brwan secure
          ovs-vsctl set bridge brwan other-config:datapath-id=0000000000000001
          ovs-vsctl set-controller brwan tcp:127.0.0.1:6633

          # Esperar a que el datapath aparezca en la API REST para luego poder cargar flujos
          until curl -s http://127.0.0.1:8080/stats/switches | grep -q "\\[1\\]"; do
            echo "...Esperando API REST de Ryu..."
            sleep 1
          done

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

#########################################################################
#  Servicio NodePort API_REST
#########################################################################
resource "kubernetes_service" "vnf_wan" {
  for_each = local.vnf_wan_instances

  metadata {
    name      = "vnf-wan-${each.key}-service"
    namespace = "rdsv"
  }

  spec {
    type = "NodePort"
    selector = {
      "k8s-app" = "vnf-wan-${each.key}"
    }

    # API REST de Ryu (8080)
    port {
      name        = "ryu-rest"
      protocol    = "TCP"
      port        = 8080
      target_port = 8080
      node_port   = each.key == "site1" ? 31880 : 31881
    }
  }
}

#########################################################################
#  Servicio headless → expone la IP real del Pod WAN
#########################################################################
resource "kubernetes_service" "vnf_wan_pod" {
  for_each = local.vnf_wan_instances

  metadata {
    name      = "vnf-wan-${each.key}-pod"
    namespace = "rdsv"
  }

  spec {
    cluster_ip = "None"
    selector   = { "k8s-app" = "vnf-wan-${each.key}" }
  }
}

# Post-deployment script
resource "null_resource" "post_deploy_script" {
  depends_on = [
    local.vnf_wan_instances
  ]
  provisioner "local-exec" {
    command = "bash ryu-flows.sh"
  }
}
