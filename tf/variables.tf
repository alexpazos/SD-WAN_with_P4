variable "vnf_sites" {
  description = "Mapa de configuración por sitio"
  type = map(object({
    netnum     = number # Número de red del sitio
    custunip   = string # IP del túnel del cliente
    vnftunip   = string # IP del túnel de la VNF
    custprefix = string # Prefijo de la red del cliente
    vcpepubip  = string # IP pública de la vCPE
    vcpegw     = string # Puerta de enlace de la vCPE
    remotesite = string # IP pública de la vCPE del sitio remoto
  }))
}


