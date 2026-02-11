from locust import HttpUser, task, between
import json
import random

class EventUser(HttpUser):
    wait_time = between(0.1, 0.5)

    event_types = ['data_transformation', 'notification', 'analytics', 'computation']

    @task(10)
    def submit_event(self):
        """Submit a random event"""
        event_type = random.choice(self.event_types)

        payload = {
            'event_type': event_type,
            'payload': {
                'record_count': random.randint(100, 1000),
                'data_points': random.randint(500, 5000),
                'value': random.randint(1, 100)
            },
            'priority': random.randint(1, 10)
        }

        with self.client.post(
            "/events",
            json=payload,
            catch_response=True
        ) as response:
            if response.status_code == 200:
                response.success()
            else:
                response.failure(f"Failed with status {response.status_code}")

    @task(2)
    def check_stats(self):
        """Check system stats"""
        self.client.get("/stats")

    @task(1)
    def health_check(self):
        """Health check"""
        self.client.get("/health")

# Run with: locust -f locustfile.py --host=http://YOUR_ALB_URL
# For load test: locust -f locustfile.py --host=http://YOUR_ALB_URL --users 1000 --spawn-rate 50 --run-time 10m --headless
