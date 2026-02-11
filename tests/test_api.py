import pytest
from fastapi.testclient import TestClient
from api.app import app
from unittest.mock import patch, MagicMock

client = TestClient(app)

@patch('api.app.sqs')
@patch('api.app.table')
def test_submit_event(mock_table, mock_sqs):
    mock_sqs.send_message.return_value = {'MessageId': 'test-123'}
    mock_table.put_item.return_value = {}

    response = client.post("/events", json={
        "event_type": "test",
        "payload": {"test": "data"}
    })

    assert response.status_code == 200
    assert "event_id" in response.json()
    assert response.json()["status"] == "queued"

@patch('api.app.sqs')
def test_health_check(mock_sqs):
    mock_sqs.get_queue_attributes.return_value = {'Attributes': {}}

    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"

def test_metrics_endpoint():
    response = client.get("/metrics")
    assert response.status_code == 200
