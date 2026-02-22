#!/bin/bash

set -e

BASE_DIR="$HOME/terraform-sdwan"

echo "Despliegue KNF"


cd "$BASE_DIR/tf"
terraform init
terraform apply --var-file=dev2.tfvars



# cd "$BASE_DIR/bin"
# ./sdw-knf-consoles open 2
echo "Despliegue correcto"