#!/bin/bash
set -e

BASE_DIR="$HOME/terraform-sdwan"

echo "==============================================="
echo "RDSV RETO FINAL"
echo "==============================================="


cd "$BASE_DIR/tf"
terraform destroy --var-file=dev2.tfvars

cd "$BASE_DIR/vnx"
sudo vnx -f sdedge_nfv_sedes.xml --destroy

cd "$BASE_DIR/clab"
./sdw-clab-destroy.sh

echo "Destruccion exitosa"
