import boto3
import json
import time
import os
import signal
import sys
from datetime import datetime
from typing import Dict, Any
import logging
from prometheus_client import Counter, Histogram, Gauge, start_http_server
from processor import EventProcessor

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

events_processed = Counter('worker_events_processed_total', 'Total events processed', ['status'])
processing_latency = Histogram('worker_processing_latency_seconds', 'Event processing latency')
queue_polling_errors = Counter('worker_queue_polling_errors_total', 'Queue polling errors')
active_workers = Gauge('worker_active_count', 'Number of active workers')
retry_attempts = Counter('worker_retry_attempts_total', 'Total retry attempts')

class Worker:
    def __init__(self):
        self.sqs = boto3.client('sqs', region_name=os.getenv('AWS_REGION', 'us-east-1'))
        self.dynamodb = boto3.resource('dynamodb', region_name=os.getenv('AWS_REGION', 'us-east-1'))
        self.queue_url = os.getenv('SQS_QUEUE_URL')
        self.dlq_url = os.getenv('SQS_DLQ_URL')
        self.table_name = os.getenv('DYNAMODB_TABLE_NAME', 'events')
        self.table = self.dynamodb.Table(self.table_name)

        self.processor = EventProcessor()
        self.running = True
        self.worker_id = os.getenv('WORKER_ID', 'worker-' + str(os.getpid()))

        signal.signal(signal.SIGTERM, self.shutdown)
        signal.signal(signal.SIGINT, self.shutdown)

        logger.info(f"Worker {self.worker_id} initialized")

    def shutdown(self, signum, frame):
        logger.info(f"Worker {self.worker_id} shutting down gracefully...")
        self.running = False
        active_workers.dec()
        sys.exit(0)

    def update_event_status(self, event_id: str, status: str, result: Any = None, error: str = None):
        try:
            update_expr = "SET #status = :status, processed_at = :processed_at"
            expr_values = {
                ':status': status,
                ':processed_at': datetime.utcnow().isoformat()
            }
            expr_names = {'#status': 'status'}

            if result is not None:
                update_expr += ", result = :result"
                expr_values[':result'] = json.dumps(result)

            if error is not None:
                update_expr += ", error = :error"
                expr_values[':error'] = error

            self.table.update_item(
                Key={'event_id': event_id},
                UpdateExpression=update_expr,
                ExpressionAttributeNames=expr_names,
                ExpressionAttributeValues=expr_values
            )
        except Exception as e:
            logger.error(f"Failed to update event status: {str(e)}")

    def process_message(self, message: Dict[str, Any], receipt_handle: str, attempt: int = 0) -> bool:
        start_time = time.time()

        try:
            body = json.loads(message['Body'])
            event_id = body['event_id']
            event_type = body['event_type']
            payload = body['payload']

            logger.info(f"Processing event {event_id} (type: {event_type})")

            self.update_event_status(event_id, 'processing')

            result = self.processor.process(event_type, payload)

            self.update_event_status(event_id, 'completed', result=result)

            self.sqs.delete_message(
                QueueUrl=self.queue_url,
                ReceiptHandle=receipt_handle
            )

            events_processed.labels(status='success').inc()
            processing_latency.observe(time.time() - start_time)

            logger.info(f"Successfully processed event {event_id} in {time.time() - start_time:.2f}s")
            return True

        except Exception as e:
            logger.error(f"Error processing message (attempt {attempt}): {str(e)}")

            max_retries = 3
            if attempt < max_retries:
                retry_attempts.inc()
                backoff = 2 ** attempt
                logger.info(f"Retrying in {backoff} seconds...")
                time.sleep(backoff)
                return self.process_message(message, receipt_handle, attempt + 1)
            else:
                logger.error(f"Max retries exceeded, moving to DLQ")
                try:
                    body = json.loads(message['Body'])
                    event_id = body['event_id']

                    self.update_event_status(event_id, 'failed', error=str(e))

                    if self.dlq_url:
                        self.sqs.send_message(
                            QueueUrl=self.dlq_url,
                            MessageBody=message['Body']
                        )

                    self.sqs.delete_message(
                        QueueUrl=self.queue_url,
                        ReceiptHandle=receipt_handle
                    )

                    events_processed.labels(status='failed').inc()
                except Exception as dlq_error:
                    logger.error(f"Failed to handle DLQ: {str(dlq_error)}")

                return False

    def run(self):
        logger.info(f"Worker {self.worker_id} starting...")
        active_workers.inc()

        metrics_port = int(os.getenv('WORKER_METRICS_PORT', 8001))
        start_http_server(metrics_port)
        logger.info(f"Metrics server started on port {metrics_port}")

        while self.running:
            try:
                response = self.sqs.receive_message(
                    QueueUrl=self.queue_url,
                    MaxNumberOfMessages=10,
                    WaitTimeSeconds=20,
                    MessageAttributeNames=['All']
                )

                messages = response.get('Messages', [])

                if not messages:
                    logger.debug("No messages received")
                    continue

                logger.info(f"Received {len(messages)} messages")

                for message in messages:
                    if not self.running:
                        break

                    self.process_message(message, message['ReceiptHandle'])

            except Exception as e:
                logger.error(f"Error in worker loop: {str(e)}")
                queue_polling_errors.inc()
                time.sleep(5)

if __name__ == "__main__":
    worker = Worker()
    worker.run()
