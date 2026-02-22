locals {
  vnf_access_instances = {
    for site, cfg in var.vnf_sites : site => merge(cfg, {
      cpe_service_name = "vnf-cpe-service-${site}"
    })
  }

  vnf_cpe_instances = {
    for site, cfg in var.vnf_sites : site => merge(cfg, {
      access_service_name = "vnf-access-${site}-service"
    })
  }
  vnf_wan_instances = {
    for site, cfg in var.vnf_sites : site => merge(cfg, {
      access_ip = cfg.vnftunip
      cpe_service_name  = "vnf-cpe-service-${site}" 
    })
  }

  vnf_ctrl_instances = {
    for site, cfg in var.vnf_sites : site => cfg
  }

} 