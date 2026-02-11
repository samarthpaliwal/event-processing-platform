import time
import random
import hashlib
import json
from typing import Dict, Any

class EventProcessor:
    def __init__(self):
        self.processed_cache = {}

    def _generate_idempotency_key(self, event_type: str, payload: Dict[str, Any]) -> str:
        content = f"{event_type}:{json.dumps(payload, sort_keys=True)}"
        return hashlib.sha256(content.encode()).hexdigest()

    def process(self, event_type: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        idempotency_key = self._generate_idempotency_key(event_type, payload)
        if idempotency_key in self.processed_cache:
            return self.processed_cache[idempotency_key]

        handlers = {
            'data_transformation': self._handle_data_transformation,
            'notification': self._handle_notification,
            'analytics': self._handle_analytics,
            'computation': self._handle_computation,
        }

        handler = handlers.get(event_type, self._handle_default)
        result = handler(payload)

        self.processed_cache[idempotency_key] = result

        return result

    def _handle_data_transformation(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        time.sleep(random.uniform(0.1, 0.5))

        return {
            'transformed': True,
            'records_processed': payload.get('record_count', 100),
            'output_size': payload.get('record_count', 100) * 1.2
        }

    def _handle_notification(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        time.sleep(random.uniform(0.05, 0.2))

        return {
            'sent': True,
            'recipient': payload.get('recipient', 'unknown'),
            'timestamp': time.time()
        }

    def _handle_analytics(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        time.sleep(random.uniform(0.2, 0.8))

        return {
            'analyzed': True,
            'metrics_computed': ['avg', 'count', 'percentiles'],
            'data_points': payload.get('data_points', 1000)
        }

    def _handle_computation(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        time.sleep(random.uniform(0.5, 1.5))

        value = payload.get('value', 1)
        result = sum(i ** 2 for i in range(1000))

        return {
            'computed': True,
            'result': result,
            'computation_time': 'variable'
        }

    def _handle_default(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        time.sleep(random.uniform(0.1, 0.3))

        return {
            'processed': True,
            'payload_size': len(json.dumps(payload))
        }
