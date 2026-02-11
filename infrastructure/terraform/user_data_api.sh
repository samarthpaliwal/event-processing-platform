#!/bin/bash
set -e

# Update system
yum update -y

# Install Python 3.9
yum install -y python3.9 python3.9-pip git

# Clone repository (replace with your repo)
cd /home/ec2-user
git clone https://github.com/YOUR_USERNAME/event-processing-platform.git || true
cd event-processing-platform/api

# Install dependencies
pip3.9 install -r requirements.txt

# Set environment variables
export SQS_QUEUE_URL="${sqs_queue_url}"
export DYNAMODB_TABLE_NAME="${dynamodb_table_name}"
export AWS_REGION="${aws_region}"

# Create systemd service
cat > /etc/systemd/system/api.service <<EOF
[Unit]
Description=Event Processing API
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/home/ec2-user/event-processing-platform/api
Environment="SQS_QUEUE_URL=${sqs_queue_url}"
Environment="DYNAMODB_TABLE_NAME=${dynamodb_table_name}"
Environment="AWS_REGION=${aws_region}"
ExecStart=/usr/bin/python3.9 -m uvicorn app:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Start service
systemctl daemon-reload
systemctl enable api
systemctl start api
