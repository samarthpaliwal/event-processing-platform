# Scalable Event Processing Platform

A distributed event-processing system in Python: a FastAPI service accepts events over HTTP, writes them to an SQS queue and a DynamoDB table, and a fleet of worker processes consumes the queue, runs a handler per event type, retries with exponential backoff, and parks failures in a dead-letter queue. It runs locally against LocalStack with Docker Compose, and ships Terraform for an AWS deployment (EC2 auto-scaling groups behind an ALB, CloudWatch scaling on queue depth), Prometheus and Grafana configuration, a Locust load test, pytest unit tests and a GitHub Actions pipeline.

## Requirements

- Docker and Docker Compose
- Python 3.9 (the Dockerfiles use `python:3.9-slim`; CI uses 3.9) with `pip`
- For local setup: `localstack` and `awscli-local` (`awslocal`), installed by `scripts/local-setup.sh`
- For load testing: `locust`
- For AWS deployment: an AWS account, the AWS CLI configured, and Terraform

## Setup

Both the API and the worker read their configuration from environment variables. `docker-compose.yml` sets them for the LocalStack environment; `infrastructure/terraform/user_data_*.sh` set them on EC2.

| Variable | Used by | Purpose |
|---|---|---|
| `AWS_REGION` | api, worker | AWS region (default `us-east-1`) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | api, worker | Credentials (`test`/`test` for LocalStack) |
| `AWS_ENDPOINT_URL` | api, worker | Set to `http://localstack:4566` locally; unset on AWS |
| `SQS_QUEUE_URL` | api, worker | Main queue URL |
| `SQS_DLQ_URL` | worker | Dead-letter queue URL |
| `DYNAMODB_TABLE_NAME` | api, worker | Events table (default `events`) |
| `WORKER_ID` | worker | Label for logs (default `worker-<pid>`) |
| `WORKER_METRICS_PORT` | worker | Prometheus port (default `8001`) |

Example for running the services outside Docker against LocalStack:

```env
# .env.example
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_ENDPOINT_URL=http://localhost:4566
SQS_QUEUE_URL=http://localhost:4566/000000000000/event-queue
SQS_DLQ_URL=http://localhost:4566/000000000000/event-dlq
DYNAMODB_TABLE_NAME=events
```

For AWS deployment, edit `infrastructure/terraform/variables.tf` (`aws_region`, `project_name`, `api_instance_type`, `worker_instance_type`; all `t3.medium` by default) and add `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as GitHub Actions secrets.

## Usage

### Local development

1. Create the LocalStack queues and table (starts the `localstack` container, then creates `event-queue`, `event-dlq` and the `events` table):

   ```bash
   chmod +x scripts/local-setup.sh
   ./scripts/local-setup.sh
   ```

2. Start everything:

   ```bash
   docker compose up
   ```

   This builds and runs the API on http://localhost:8000, the worker (the compose file declares 3 replicas under `deploy:`, which plain Compose ignores; use `docker compose up --scale worker=3` to get three), Prometheus on http://localhost:9090 and Grafana on http://localhost:3000 (login `admin` / `admin`).

3. Submit an event and check it:

   ```bash
   curl -X POST http://localhost:8000/events \
     -H "Content-Type: application/json" \
     -d '{"event_type": "test", "payload": {"data": "test"}}'
   # {"event_id":"...","status":"queued",...}

   curl http://localhost:8000/events/<event_id>   # status moves queued -> processing -> completed
   curl http://localhost:8000/stats               # queue depth and in-flight count
   ```

Alternatively run the processes directly, as `local-setup.sh` prints: `cd api && uvicorn app:app --reload` and `cd worker && python worker.py` (with the variables above exported).

### Tests

```bash
pip install -r api/requirements.txt -r worker/requirements.txt pytest
pytest tests/
```

Five tests: three for the API with mocked SQS/DynamoDB (submit, health, metrics) and two for the processor (handler result, idempotency).

### Load testing

```bash
chmod +x scripts/load-test.sh
./scripts/load-test.sh http://YOUR_API_URL 1000 50 10m
# arguments: host, users (default 1000), spawn rate (default 50), run time (default 10m)
```

Runs `load-testing/locustfile.py` headless and writes `load-testing/report.html`. The Locust user posts random events (weight 10), polls `/stats` (2) and `/health` (1) with 0.1 to 0.5 s waits.

### AWS deployment

```bash
aws configure
cd infrastructure/terraform
terraform init
terraform plan
terraform apply
```

The GitHub Actions workflow (`.github/workflows/deploy.yml`) runs pytest on every push and pull request to `main`; on pushes to `main` it also builds and pushes the API and worker images to ECR and runs `terraform apply -auto-approve`.

## How it works

- **API** (`api/app.py`): FastAPI with `POST /events` (validates the body with Pydantic, generates a UUID, `sqs.send_message`, `table.put_item` with status `queued`), `GET /events/{event_id}` (reads DynamoDB), `GET /stats` (SQS approximate message counts), `GET /health` (checks the queue is reachable) and `GET /metrics` (Prometheus counters and a latency histogram).
- **Worker** (`worker/worker.py`): long-polls SQS (`WaitTimeSeconds=20`, up to 10 messages), marks the event `processing`, calls `EventProcessor.process`, marks it `completed` with the result and deletes the message. On exception it retries in-process up to 3 times with backoff of 1, 2, 4 seconds; after that it marks the event `failed`, copies the body to the DLQ and deletes the original. `SIGTERM`/`SIGINT` set a stop flag so the loop exits after the current batch. It serves its own Prometheus metrics on port 8001.
- **Processor** (`worker/processor.py`): dispatches on `event_type` (`data_transformation`, `notification`, `analytics`, `computation`, or a default) to handlers that sleep for a short random time and return a small result dict. It keeps an in-memory dictionary keyed by a SHA-256 of type plus payload, so a repeated identical event inside one worker process returns the cached result. The cache is per process and not shared or persisted.
- **Infrastructure** (`infrastructure/terraform/main.tf`): VPC with public subnets, security groups, SQS queue with a redrive policy to the DLQ after 3 receives, DynamoDB table (on-demand billing) with a GSI, IAM role and instance profile, ALB and target group, launch templates and two auto-scaling groups: API 2 to 10 instances, workers 3 to 20 instances. Workers scale out by 2 when `ApproximateNumberOfMessagesVisible` stays above 1000 for 2 minutes and scale in by 1 when it stays below 100 for 10 minutes.
- **Monitoring**: `monitoring/prometheus.yml` scrapes the API at `api:8000/metrics` and discovers workers through EC2 service discovery on port 8001 (the worker scrape therefore only works on AWS, not in Compose). `monitoring/grafana-dashboard.json` is a dashboard definition to import by hand; Compose does not auto-provision it.

## Project layout

```
event-processing-platform/
├── api/
│   ├── app.py                 # FastAPI application
│   └── requirements.txt
├── worker/
│   ├── worker.py              # SQS consumer loop, retries, DLQ, metrics
│   ├── processor.py           # Per-event-type handlers, in-memory idempotency cache
│   └── requirements.txt
├── infrastructure/
│   ├── docker/                # Dockerfile.api, Dockerfile.worker
│   └── terraform/             # main.tf, variables.tf, outputs.tf, user_data_*.sh
├── monitoring/                # prometheus.yml, grafana-dashboard.json
├── load-testing/locustfile.py
├── tests/                     # test_api.py, test_worker.py
├── scripts/                   # local-setup.sh, load-test.sh, setup.sh
├── docker-compose.yml         # localstack, api, worker, prometheus, grafana
└── .github/workflows/deploy.yml
```
