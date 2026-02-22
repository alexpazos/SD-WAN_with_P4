resource "kubernetes_pod" "vnf_ctrl" {
  for_each = local.vnf_ctrl_instances

  metadata {
    name      = "vnf-ctrl-${each.key}"
    namespace = "rdsv"
    labels = { "k8s-app" = "vnf-ctrl-${each.key}" }
  }

  spec {
    container {
      name  = "vnf-ctrl"
      image = "docker.io/lucasvg7/vnf-ctrl:latest"


      command = ["/bin/sh","-c",<<-EOT
        

      ryu-manager /root/qos_simple_switch_13.py /root/flowmanager/flowmanager.py ryu.app.rest_qos ryu.app.rest_conf_switch ryu.app.ofctl_rest 
      EOT
      ]
    }
  }
}

resource "kubernetes_service" "vnf_ctrl" {
  for_each = local.vnf_ctrl_instances

  metadata {
    name      = "vnf-ctrl-${each.key}-service"
    namespace = "rdsv"
  }

  spec {
    type = "NodePort"
    selector = { "k8s-app" = "vnf-ctrl-${each.key}" }

    port {
      name        = "openflow"
      port        = 6633
      target_port = 6633
    }

    port {
      name        = "ryu-rest"
      port        = 8080
      target_port = 8080
      node_port   = each.key == "site1" ? 31808 : 31809
    }
  }
}


