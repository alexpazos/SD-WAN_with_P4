#!/bin/bash

echo "Kafka subscrito a interface-status"
docker exec -it kafka kafka-console-consumer.sh --topic interface-status --bootstrap-server kafka:9092 --from-beginning

