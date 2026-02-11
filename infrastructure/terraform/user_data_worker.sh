#!/bin/bash
set -e

# Update system
yum update -y

# Install Python 3.9
yum install -y python3.9 python3.9-pip git

# Clone repository
cd /home/ec2-user
git clone https://github.com/samarthpaliwal/event-processing-platform.git || true
cd event-processing-platform/worker

# Install dependencies
pip3.9 install -r requirements.txt

# Set environment variables
export SQS_QUEUE_URL="${sqs_queue_url}"
export SQS_DLQ_URL="${sqs_dlq_url}"
export DYNAMODB_TABLE_NAME="${dynamodb_table_name}"
export AWS_REGION="${aws_region}"
export WORKER_ID="worker-$(hostname)"

# Create systemd service
cat > /etc/systemd/system/worker.service <<EOF
[Unit]
Description=Event Processing Worker
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/home/ec2-user/event-processing-platform/worker
Environment="SQS_QUEUE_URL=${sqs_queue_url}"
Environment="SQS_DLQ_URL=${sqs_dlq_url}"
Environment="DYNAMODB_TABLE_NAME=${dynamodb_table_name}"
Environment="AWS_REGION=${aws_region}"
Environment="WORKER_ID=worker-$(hostname)"
ExecStart=/usr/bin/python3.9 worker.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Start service
systemctl daemon-reload
systemctl enable worker
systemctl start worker
