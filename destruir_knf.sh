#!/bin/bash
set -e

BASE_DIR="$HOME/terraform-sdwan"

echo "Destruir KNF"

cd "$BASE_DIR/tf"
terraform destroy --var-file=dev2.tfvars
echo "Destrucción correcta"