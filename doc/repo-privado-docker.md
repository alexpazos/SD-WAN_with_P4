> **RDSV/SDNV**
>
> Curso 2025-26
>
# Reto RDSV/SDNV - Repositorio privado de imágenes Docker en MicroK8s

## Introducción

Tener un registro privado de imágenes Docker en nuestro entorno o cluster de
Kubernetes puede mejorar significativamente la productividad y acelerar el
desarrollo al reducir el tiempo dedicado a cargar y descargar imágenes de Docker
desde repositorios públicos accesibles desde Internet como Docker Hub. Una vez
que este servicio de registro privado esté disponible en un entorno Kubernetes,
permitirá cargar imágenes Docker personalizadas que podrán ser usadas
directamente por las aplicaciones o los servicios desplegados en el propio
entorno Kubernetes sin la necesidad de acceder a repositorios públicos.

## Pasos a seguir

Pasos para instalar y trabajar con el registro privado de imágenes Docker en
MicroK8s:

1. En primer lugar, en MicroK8s (desde la máquina virtual) hay que habilitar el servicio *registry* dedicado para el registro de imágenes Docker mediante el siguiente comando:
    ```shell
    $ sudo microk8s enable registry
    ```

2. Por defecto, el servicio *registry* se expone en el endpoint *localhost:32000*. 

3. Si queremos hacer uso de este servicio privado de imágenes
Docker desde una máquina externa diferente al servidor que gestiona Kubernetes, es
necesario indicar el endpoint asociado como confiable en el fichero
`/etc/docker/daemon.json` de la máquina externa de la siguiente manera:
    ```shell
    {
    "insecure-registries" : ["<IP_MicroK8s_server>:32000"]
    }
    ```

    , siendo `<IP_MicroK8s_server>` la IP de acceso al servidor de Kubernetes (en nuestro caso, la IP de la máquina virtual).

    Posteriormente, habría que reiniciar el servicio de Docker en la máquina externa para cargar la nueva configuración mediante la ejecución del comando siguiente:
    ```shell
    $ sudo systemctl restart docker
    ```

    >**Nota:**  Si construimos la imagen Docker en la misma máquina virtual que gestiona el entorno de Kubernetes, no hace falta seguir el paso anterior.

4. Las imágenes Docker que se construyan deben etiquetarse con el endpoint asociado al registro privado antes de cargarlas en él. Para ello, suponiendo que nos encontramos en el mismo directorio donde se encuentra el archivo Dockerfile
a partir del cuál queremos construir una imagen Docker que cargaremos en nuestro registro privado, ejecutamos el siguiente comando:
    ```shell
    $ docker build . -t <IP_MicroK8s_server>:32000/<nombre_imagen>:<version> 
    ```

    , siendo `<IP_MicroK8s_server>` la IP de acceso al servidor de Kubernetes (en nuestro caso valdría con *localhost*), `<nombre_imagen>` el nombre que queremos que tenga la imagen Docker en el repositorio y `<version>` la versión de la misma (por ejemplo, latest).

5. Ahora que la imagen Docker ha sido correctamente construida y etiquetada, apuntando al registro correspondiente, podemos cargarla en el registro de la siguiente forma:
    ```shell
    $ docker push <IP_MicroK8s_server>:32000/<nombre_imagen>:<version>
    ```

6. Para verificar si las imágenes de Docker se han creado y almacenado
correctamente en el repositorio, puede usar la API de registro de Docker, que le
permite listar las imágenes de Docker disponibles en cualquier momento en el
registro privado de Kubernetes con la siguiente solicitud:
    ```shell
    $ curl http:// <IP_MicroK8s_server>:32000/v2/_catalog
    ```

    Y debería generar un resultado similar al siguiente:
    ```shell
    {"repositories": ["<image_name>"]}
    ```

7. Además, puedes consultar la lista de las diferentes versiones asociadas a
una imagen específica de Docker cargada en el repositorio con la siguiente
    solicitud:
    ```shell
    $ curl http:// <IP_MicroK8s_server>:32000/v2/<image_name>/tags/list
    ```

    Que debería generar un resultado similar al siguiente:
    ```shell
    {"name":"<image_name>","tags": ["<version>"]}
    ```

8. Una vez configurado el registro de imágenes Docker en MicroK8s y cargada una
imagen concreta en él, para que la imagen sea utilizada por un servicio
desplegado en Kubernetes, siempre hay que apuntar a ella indicando además el
registro privado donde se encuentra de la siguiente manera:
`<IP_MicroK8s_server>:32000/<nombre_imagen>:<version>`

    >**Nota:**  En en trabajo final, hay que actualizar los ficheros de Terraform que especifican la configuración de las KNFs para que ahora usen una imagen precargada en el repositorio privado de imágenes Docker. Para ello, tendrá que modificar de forma adecuada el apartado "image" asociado a la especificación de la imagen usada por el contenedor que utilice cada KNF. Este apartado "image" debe ser definido como `localhost:32000/<nombre_imagen>:<version>`.