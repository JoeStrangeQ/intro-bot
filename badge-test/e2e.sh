#!/usr/bin/env bash
# Starts a fake badge API and the Intro Bot server, then runs two simulated badges through
# the whole flow (badge-test/sim.lua).   bash badge-test/e2e.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DATA=$(mktemp -d)
node badge-test/fake-badge-api.mjs 8790 >/dev/null &
FAKE_PID=$!
sleep 0.5
DATA_DIR=$DATA PORT=8791 TICK_MS=300 BADGE_API=http://127.0.0.1:8790 \
  ESCROW_KEY=test-escrow-key APP_KEY=test-app-key PUBLIC_URL=https://relay.botbotcap.com \
  node services/relay/src/server.ts >"$DATA/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $FAKE_PID $SERVER_PID 2>/dev/null; rm -rf "$DATA"' EXIT
for _ in $(seq 20); do curl -fs http://127.0.0.1:8791/health >/dev/null && break; sleep 0.2; done
FLOATS=${FLOATS:-1} lua badge-test/sim.lua || { cat "$DATA/server.log"; exit 1; }
