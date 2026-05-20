# SSE Reconnect Validation

Quick check that the SSE endpoint reconnects after a dropped connection.

1. Open the stream: `curl -N http://localhost:8080/events`
2. Restart the API container: `docker compose restart api`
3. Confirm the client resumes receiving events without manual retry.
