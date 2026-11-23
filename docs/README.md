# Media

`docs/dashboard.png` is not committed yet. The README has a slot for it under the tagline.

TODO: capture it.

1. `docker compose up --scale worker=3`
2. Open Grafana at http://localhost:3000 (admin / admin), add Prometheus (`http://prometheus:9090`) as a
   data source and import `monitoring/grafana-dashboard.json`.
3. Run `./scripts/load-test.sh http://localhost:8000 200 20 2m` so the panels have data.
4. Screenshot the dashboard at about 1600 px wide, save it as `docs/dashboard.png`, and uncomment the
   image line near the top of the README.

If you run the load test, also commit `load-testing/report.html` (or its summary numbers) so the Results
section can quote a measured throughput.
