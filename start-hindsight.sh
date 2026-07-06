#!/usr/bin/env bash
# Start hindsight daemon in foreground (systemd supervises the process)
set -euo pipefail

# Postgres is managed by hindsight-postgres.service — assume it is running on 5433
# Env vars (DB URL, LLM key, provider, model, port) come from systemd unit Environment=

exec /home/ale/.hermes/hermes-agent/venv/bin/hindsight-api --idle-timeout 0 --port 8888
