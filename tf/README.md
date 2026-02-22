# TFM – Proyecto Terraform para SD-WAN
## Descripción del proyecto
Este proyecto implementa una arquitectura **SD-WAN (Software-Defined Wide Area Network)** utilizando **infraestructura como código (IaC)** como **Terraform**, controladores SDN con **Ryu**, y monitoreo con **Prometheus** y **Grafana**.
La solución se compone de múltiples **KNFs (Kubernetes Network Functions)** que representan funciones de red virtualizadas, desplegadas automáticamente mediante scripts de Terraform.
Este proyecto tiene como objetivo configurar los switches dentro de las KNFs para que sean controlados mediante OpenFlow desde el controlador SDN Ryu. Se busca garantizar la conectividad IPv4 dentro de la red corporativa y su acceso a Internet. 

La siguiente figura representa la arquitectura del entorno implementado, detallando los componentes clave y sus interacciones dentro de la red.

<img alt="image" src="../doc/img/global-arch-tun.png" />


## Componentes Principales
- **KNF:access, KNF:cpe, KNF:wan**  
  Funciones de red virtualizadas (VNFs) configuradas con Terraform. Representan nodos de acceso, operación y conectividad.

- **Ryu**  
  Controlador SDN que gestiona las reglas de enrutamiento y reenvío dinámicamente en la red. Controla el flujo de tráfico a través de OpenFlow.

---

## 🛠️ Requisitos

- [Terraform](https://www.terraform.io/downloads.html) v1.x  
- [Git](https://git-scm.com/)  

---
## 🛠️ Instalación y Configuración

1. **Clonar el repositorio:**

    ```bash
    git clone https://github.com/educaredes/terraform-sdwan.git
    cd tf
    ```

2. **Inicializa Terraform:**

    ```bash
    terraform init
    ```

3. **Previsualiza los cambios:**

    ```bash
    terraform plan
    ```

4. **Aplicar la configuración**

    ```bash
    terraform apply --var-file=dev2.tfvars
    ```

4. **Averiguar el estado de un pod y de un servicio de un site**

    ```bash
    # pod
    terraform state show kubernetes_pod.vnf_access[\"site1\"]
    # servicio
    terraform state show kubernetes_service.vnf_access[\"site1\"]
    ```

5. **Aplicar las reglas**

    ```bash
   chmod +x apply_flow.sh
   ./apply_flow.sh
    ```






