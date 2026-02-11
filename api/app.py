from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional, Dict, Any
import boto3
import json
import time
import uuid
from datetime import datetime
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from fastapi.responses import Response
import os

# Prometheus metrics
request_counter = Counter('api_requests_total', 'Total API requests', ['method', 'endpoint', 'status'])
request_latency = Histogram('api_request_latency_seconds', 'API request latency', ['endpoint'])
event_submitted = Counter('events_submitted_total', 'Total events submitted')
event_errors = Counter('event_errors_total', 'Total event submission errors')

app = FastAPI(title="Event Processing Platform")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# AWS clients
sqs = boto3.client('sqs', region_name=os.getenv('AWS_REGION', 'us-east-1'))
dynamodb = boto3.resource('dynamodb', region_name=os.getenv('AWS_REGION', 'us-east-1'))

QUEUE_URL = os.getenv('SQS_QUEUE_URL')
TABLE_NAME = os.getenv('DYNAMODB_TABLE_NAME', 'events')
table = dynamodb.Table(TABLE_NAME)

class Event(BaseModel):
    event_type: str
    payload: Dict[str, Any]
    priority: Optional[int] = 5
    metadata: Optional[Dict[str, Any]] = {}

class EventResponse(BaseModel):
    event_id: str
    status: str
    timestamp: str
    message: str

@app.get("/health")
async def health_check():
    try:
        sqs.get_queue_attributes(QueueUrl=QUEUE_URL, AttributeNames=['ApproximateNumberOfMessages'])
        return {"status": "healthy", "timestamp": datetime.utcnow().isoformat()}
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Service unhealthy: {str(e)}")

@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.post("/events", response_model=EventResponse)
async def submit_event(event: Event):
    start_time = time.time()

    try:
        event_id = str(uuid.uuid4())
        timestamp = datetime.utcnow().isoformat()

        message = {
            'event_id': event_id,
            'event_type': event.event_type,
            'payload': event.payload,
            'priority': event.priority,
            'metadata': event.metadata,
            'submitted_at': timestamp,
            'status': 'queued'
        }

        response = sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(message),
            MessageAttributes={
                'event_type': {'StringValue': event.event_type, 'DataType': 'String'},
                'priority': {'StringValue': str(event.priority), 'DataType': 'Number'}
            }
        )

        table.put_item(Item={
            'event_id': event_id,
            'event_type': event.event_type,
            'payload': json.dumps(event.payload),
            'priority': event.priority,
            'status': 'queued',
            'submitted_at': timestamp,
            'message_id': response['MessageId']
        })

        event_submitted.inc()
        request_counter.labels(method='POST', endpoint='/events', status='200').inc()
        request_latency.labels(endpoint='/events').observe(time.time() - start_time)

        return EventResponse(
            event_id=event_id,
            status='queued',
            timestamp=timestamp,
            message='Event submitted successfully'
        )

    except Exception as e:
        event_errors.inc()
        request_counter.labels(method='POST', endpoint='/events', status='500').inc()
        raise HTTPException(status_code=500, detail=f"Failed to submit event: {str(e)}")

@app.get("/events/{event_id}")
async def get_event(event_id: str):
    try:
        response = table.get_item(Key={'event_id': event_id})

        if 'Item' not in response:
            raise HTTPException(status_code=404, detail="Event not found")

        item = response['Item']
        return {
            'event_id': item['event_id'],
            'status': item['status'],
            'event_type': item['event_type'],
            'submitted_at': item['submitted_at'],
            'processed_at': item.get('processed_at'),
            'result': item.get('result')
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to retrieve event: {str(e)}")

@app.get("/stats")
async def get_stats():
    try:
        queue_attrs = sqs.get_queue_attributes(
            QueueUrl=QUEUE_URL,
            AttributeNames=['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible']
        )

        return {
            'queue_depth': int(queue_attrs['Attributes']['ApproximateNumberOfMessages']),
            'messages_in_flight': int(queue_attrs['Attributes']['ApproximateNumberOfMessagesNotVisible']),
            'timestamp': datetime.utcnow().isoformat()
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to retrieve stats: {str(e)}")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
