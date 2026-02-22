# vnf-p4-sdwan.tf
# Switch P4 simplificado con 3 puertos: Cliente, MPLS, Internet

# provider "kubernetes" {
#   config_path = "~/.kube/config"
# }

locals {
  # Instancias del switch P4 (una por site)
  p4_sdwan_instances = {
    for site_key, site_config in var.vnf_sites :
    site_key => merge(site_config, {
      site_name = site_key
    })
  }
}

#########################################################################
# POD: Switch P4 SD-WAN Simplificado
#########################################################################

resource "kubernetes_pod" "vnf_p4_sdwan" {
  for_each = local.p4_sdwan_instances

  metadata {
    name      = "vnf-p4-sdwan-${each.key}"
    namespace = "rdsv"
    labels = {
      "k8s-app" = "vnf-p4-sdwan-${each.key}"
      "site"    = each.key
      "type"    = "p4switch"
    }

    # Redes adicionales:
    # - accessnet: Para túnel VXLAN al cliente (puerto 1)
    # - mplswan: Red MPLS inter-sedes (puerto 2)
    # - extnet: Salida a Internet/ISP (puerto 3)
    annotations = {
      "k8s.v1.cni.cncf.io/networks" = jsonencode([
        {
          name      = "accessnet${each.value.netnum}"
          interface = "net1"  # Puerto 1: vxlan1 (cliente)
        },
        {
          name      = "mplswan"
          interface = "net2"  # Puerto 2: MPLS
        },
        {
          name      = "extnet${each.value.netnum}"
          interface = "net3"  # Puerto 3: Internet/ISP
        }
      ])
    }
  }

  spec {
    container {
      name  = "p4switch"

      #TO DO: Crear imagen docker, publicarla e incluirla 
      #image = 

      # Variables de entorno
      env {
        name  = "P4_DEVICE_ID"
        value = "1"
      }

      env {
        name  = "P4_GRPC_PORT"
        value = "9559"
      }

      env {
        name  = "SITE_NAME"
        value = each.key
      }

      env {
        name  = "CLIENT_TUNIP"
        value = each.value.custunip
      }

      env {
        name  = "VNF_TUNIP"
        value = each.value.vnftunip
      }

      env {
        name  = "CLIENT_PREFIX"
        value = each.value.custprefix
      }

      env {
        name  = "VCPE_PUBIP"
        value = each.value.vcpepubip
      }

      env {
        name  = "VCPE_GW"
        value = each.value.vcpegw
      }

      env {
        name  = "REMOTE_SITE_IP"
        value = each.value.remotesite
      }

      # Comando de inicio del switch
      command = ["/bin/sh", "-c", <<-EOT
        set -e -x
        
        echo "Iniciando Switch P4 SD-WAN Simplificado"
        echo "Site: ${each.key}"
        
        # Configurar interfaces de red
        ip link set dev eth0 up
        ip link set dev net1 up  # accessnet (cliente)
        ip link set dev net2 up  # mplswan
        ip link set dev net3 up  # extnet (ISP)
        
        # Asignar IPs a las interfaces
        ifconfig net1 ${each.value.vnftunip}/24    # IP del túnel VNF
        ifconfig net3 ${each.value.vcpepubip}/24   # IP pública CPE
        
        echo "Configurando túnel VXLAN al cliente..."
        # VXLAN hacia el cliente
        # VNI 1: Puerto 4789 (estándar)
        ip link add vxlan1 type vxlan \
          id 1 \
          remote ${each.value.custunip} \
          dstport 4789 \
          dev net1
        ip link set vxlan1 up
        
        echo "Configurando rutas..."
        # Ruta por defecto hacia ISP
        ip route add default via ${each.value.vcpegw} dev net3
        
        # Ruta hacia el cliente
        ip route add ${each.value.custprefix} dev vxlan1
        
        echo "Compilando programa P4..."
        # Compilar programa P4 si no existe
        if [ ! -f /root/p4/compiled/sdwan-simple.json ]; then
          cd /root/p4
          p4c --target bmv2 --arch v1model \
              --p4runtime-files compiled/sdwan-simple_p4rt.txt \
              -o compiled/sdwan-simple.json \
              sdwan-simple.p4
          echo "Programa P4 compilado"
        else
          echo "Programa P4 ya compilado"
        fi
        
        echo "Iniciando simple_switch_grpc con 3 puertos..."
        echo "  Puerto 1: vxlan1 (cliente)"
        echo "  Puerto 2: net2 (MPLS)"
        echo "  Puerto 3: net3 (Internet)"
        
        # Iniciar switch bmv2 con solo 3 puertos
        exec simple_switch_grpc \
          --device-id 1 \
          --no-p4 \
          -i 1@vxlan1 \
          -i 2@net2 \
          -i 3@net3 \
          --log-console \
          --log-level info \
          -- \
          --grpc-server-addr 0.0.0.0:9559 \
          --cpu-port 255
      EOT
      ]

      # Privilegios necesarios para configuración de red
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
# SERVICE: Switch P4 (gRPC)
#########################################################################

resource "kubernetes_service" "vnf_p4_sdwan" {
  for_each = local.p4_sdwan_instances

  metadata {
    name      = "vnf-p4-sdwan-${each.key}-service"
    namespace = "rdsv"
  }

  spec {
    type = "ClusterIP"
    selector = {
      "k8s-app" = "vnf-p4-sdwan-${each.key}"
    }

    port {
      name        = "grpc"
      port        = 9559
      target_port = 9559
      protocol    = "TCP"
    }
  }
}

#########################################################################
# POD: Controlador P4
#########################################################################

resource "kubernetes_pod" "vnf_p4_controller" {
  for_each = local.p4_sdwan_instances

  metadata {
    name      = "vnf-p4ctrl-${each.key}"
    namespace = "rdsv"
    labels = {
      "k8s-app" = "vnf-p4ctrl-${each.key}"
      "site"    = each.key
      "type"    = "p4controller"
    }
  }

  spec {
    # Init container: esperar al switch
    init_container {
      name  = "wait-for-switch"
      image = "busybox:latest"
      
      command = ["/bin/sh", "-c", <<-EOT
        echo "Esperando switch P4..."
        while ! nslookup vnf-p4-sdwan-${each.key}-service.rdsv.svc.cluster.local; do
          echo "  Switch no disponible, esperando..."
          sleep 3
        done
        echo "Switch encontrado"
        echo "   Esperando 10s adicionales para que arranque gRPC..."
        sleep 10
      EOT
      ]
    }

    container {
      name  = "controller"

      #TO DO: Crear imagen y añadirla aqui
      #image = 

      env {
        name  = "SITE_NAME"
        value = each.key
      }

      env {
        name  = "CLIENT_PREFIX"
        value = each.value.custprefix
      }

      env {
        name  = "REMOTE_SITE_PREFIX"
        value = each.key == "site1" ? var.vnf_sites["site2"].custprefix : var.vnf_sites["site1"].custprefix
      }

      env {
        name  = "SWITCH_HOST"
        value = "vnf-p4-sdwan-${each.key}-service.rdsv.svc.cluster.local"
      }

      env {
        name  = "GRPC_PORT"
        value = "9559"
      }

    }
  }

  # Dependencia: el switch debe existir primero
  depends_on = [
    kubernetes_pod.vnf_p4_sdwan,
    kubernetes_service.vnf_p4_sdwan
  ]
}
