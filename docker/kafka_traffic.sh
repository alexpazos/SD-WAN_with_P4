#!/bin/bash

echo "Kafka subscrito a traffic-stats"
docker exec -it kafka kafka-console-consumer.sh --topic traffic-stats --bootstrap-server kafka:9092 --from-beginning

