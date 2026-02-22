#!/bin/bash

chmod +rx prometheus/
chmod +rx prometheus/prometheus.yaml

docker compose -f docker-compose.yaml up -d

echo "Sistema de telemetría arrancado"