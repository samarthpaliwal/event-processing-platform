import pytest
from worker.processor import EventProcessor

def test_event_processor():
    processor = EventProcessor()

    result = processor.process('data_transformation', {
        'record_count': 100
    })

    assert result['transformed'] == True
    assert result['records_processed'] == 100

def test_idempotency():
    processor = EventProcessor()

    payload = {'record_count': 100}
    result1 = processor.process('data_transformation', payload)
    result2 = processor.process('data_transformation', payload)

    assert result1 == result2
