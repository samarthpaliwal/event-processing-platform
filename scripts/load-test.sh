#!/bin/bash

# Load test script
API_URL=${1:-"http://localhost:8000"}
USERS=${2:-1000}
SPAWN_RATE=${3:-50}
RUN_TIME=${4:-"10m"}

echo "Running load test against $API_URL"
echo "Users: $USERS"
echo "Spawn rate: $SPAWN_RATE"
echo "Duration: $RUN_TIME"

cd load-testing
locust -f locustfile.py   --host=$API_URL   --users=$USERS   --spawn-rate=$SPAWN_RATE   --run-time=$RUN_TIME   --headless   --html=report.html
