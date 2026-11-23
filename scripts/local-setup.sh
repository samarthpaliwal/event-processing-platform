#!/bin/bash
set -e

echo "Setting up local development environment..."

# Install LocalStack
pip install localstack awscli-local

# Start LocalStack
docker-compose up -d localstack

# Wait for LocalStack to be ready
echo "Waiting for LocalStack..."
sleep 10

# Create SQS queues
awslocal sqs create-queue --queue-name event-queue
awslocal sqs create-queue --queue-name event-dlq

# Create DynamoDB table
awslocal dynamodb create-table   --table-name events   --attribute-definitions AttributeName=event_id,AttributeType=S   --key-schema AttributeName=event_id,KeyType=HASH   --billing-mode PAY_PER_REQUEST

echo "Local environment ready!"
echo "Start API: cd api && uvicorn app:app --reload"
echo "Start Worker: cd worker && python worker.py"
