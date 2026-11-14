#!/usr/bin/env bash
# Local end-to-end test (pnpm e2e). Nothing public: a local chain, the relay under
# `wrangler dev`, throwaway keys in target/e2e. Runs the badge flow twice:
#   1. solana-test-validator, program loaded upgradeable (no clock moves)
#   2. surfpool --offline, same program, with time travel for the 24h / 72h / 7 day paths
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
E=$ROOT/target/e2e
PROGRAM=GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC
SO=$ROOT/target/deploy/intro_escrow.so
PIDS=()

cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null || { echo "needs $1"; exit 1; }; }
for tool in solana-test-validator solana solana-keygen surfpool cargo lua node python3 curl; do need "$tool"; done

free() {
  if curl -s -m 1 "http://127.0.0.1:$1" >/dev/null 2>&1; then
    echo "port $1 is in use: stop what runs there first"
    exit 1
  fi
}
up() { # url, what, log
  for _ in $(seq 1 60); do
    curl -s -m 1 -o /dev/null "$1" && return 0
    sleep 1
  done
  echo "$2 did not start; see $3"
  exit 1
}
rpc() { # url, method, params
  curl -s "$1" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}"
}

echo "== build"
cargo build-sbf --manifest-path programs/intro-escrow/Cargo.toml --sbf-out-dir target/deploy >"$E.build.log" 2>&1 \
  || { echo "build failed; see $E.build.log"; exit 1; }

rm -rf "$E" && mkdir -p "$E"
for n in admin introer req1 req2; do
  solana-keygen new --no-bip39-passphrase --silent --force -o "$E/$n.json" >/dev/null
done
ADMIN=$(solana-keygen pubkey "$E/admin.json")

fund() { # rpc url
  for n in admin introer req1 req2; do
    solana airdrop -u "$1" 50 "$E/$n.json" --keypair "$E/admin.json" >/dev/null
  done
}
relay() { # port, rpc url, log
  (cd services/relay && exec pnpm exec wrangler dev --port "$1" --ip 127.0.0.1 \
    --var "RPC_URL:$2" >"$3" 2>&1) &
  PIDS+=($!)
  up "http://127.0.0.1:$1/tx" "relay" "$3"
}

STATUS=0

echo "== 1. solana-test-validator (upgradeable program, authority $ADMIN)"
free 8899; free 8787
solana-test-validator --reset --quiet --ledger "$E/ledger" --rpc-port 8899 \
  --upgradeable-program "$PROGRAM" "$SO" "$ADMIN" >"$E/validator.log" 2>&1 &
PIDS+=($!)
up http://127.0.0.1:8899/health "validator" "$E/validator.log"
until [ "$(rpc http://127.0.0.1:8899 getHealth '[]' | grep -c '"ok"')" = 1 ]; do sleep 1; done
fund http://127.0.0.1:8899
relay 8787 http://127.0.0.1:8899 "$E/relay.log"
RPC_URL=http://127.0.0.1:8899 node badge-test/wallet.mjs init-config "$E/admin.json" 2>/dev/null
lua badge-test/e2e.lua "$E" http://127.0.0.1:8899 http://127.0.0.1:8787 || STATUS=1
cleanup
PIDS=()

echo
echo "== 2. surfpool --offline (same program as an upgradeable account, time travel)"
free 18899; free 18787
(cd "$E" && exec surfpool start --offline --no-deploy --no-tui --port 18899 --ws-port 18900) >"$E/surfpool.log" 2>&1 &
PIDS+=($!)
up http://127.0.0.1:18899/health "surfpool" "$E/surfpool.log"
until [ "$(rpc http://127.0.0.1:18899 getHealth '[]' | grep -c '"ok"')" = 1 ]; do sleep 1; done
# The loader's two accounts, written directly: program -> programdata (authority = admin).
python3 badge-test/upgradeable.py http://127.0.0.1:18899 "$SO" "$PROGRAM" "$ADMIN"
fund http://127.0.0.1:18899
relay 18787 http://127.0.0.1:18899 "$E/relay2.log"
RPC_URL=http://127.0.0.1:18899 node badge-test/wallet.mjs init-config "$E/admin.json" 2>/dev/null
lua badge-test/e2e.lua "$E" http://127.0.0.1:18899 http://127.0.0.1:18787 time || STATUS=1

exit $STATUS
