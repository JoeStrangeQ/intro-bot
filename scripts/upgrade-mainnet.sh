#!/usr/bin/env bash
# Upgrade intro_escrow on mainnet (same program id, deployer key = upgrade authority),
# then create the fleet totals (init_stats). docs/deploy.md, "Upgrade".
#
#   scripts/upgrade-mainnet.sh
set -euo pipefail
cd "$(dirname "$0")/.."

KEYS=~/.config/intro-bot
DEPLOYER=$KEYS/deployer.json
PROGRAM=GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC
# Your mainnet RPC (e.g. Helius) lives in this file, never in the repo.
RPC_FILE=$KEYS/rpc-url
RPC_URL=${RPC_URL:-$(cat "$RPC_FILE" 2>/dev/null || true)}
[ -n "$RPC_URL" ] || { echo "put your mainnet RPC URL in $RPC_FILE"; exit 1; }
SO=target/deploy/intro_escrow.so
# The buffer (~2.0 SOL) comes back after the upgrade; a bigger program locks a little more rent.
NEED_SOL=2.2

say() { printf '\n== %s\n' "$*"; }

[ -f "$DEPLOYER" ] || { echo "missing $DEPLOYER"; exit 1; }
ME=$(solana-keygen pubkey "$DEPLOYER")

say "Build and test"
pnpm install --silent
cargo build-sbf --manifest-path programs/intro-escrow/Cargo.toml --sbf-out-dir target/deploy
cargo test -q

say "Authority and balance"
SHOW=$(solana program show "$PROGRAM" --url "$RPC_URL")
echo "$SHOW"
echo "$SHOW" | grep -q "Authority: $ME" || { echo "deployer is not the upgrade authority"; exit 1; }
BAL=$(solana balance "$ME" --url "$RPC_URL" | awk '{print $1}')
echo "deployer $ME has $BAL SOL (needs ~$NEED_SOL)"
awk -v b="$BAL" -v n="$NEED_SOL" 'BEGIN { exit !(b >= n) }' || { echo "fund it first"; exit 1; }

# The program account was made exactly as big as the first build: grow it if needed.
HAVE=$(echo "$SHOW" | awk '/Data Length:/ {print $3}')
WANT=$(stat -f%z "$SO")
if [ "$WANT" -gt "$HAVE" ]; then
  say "Extend by $((WANT - HAVE)) bytes"
  solana program extend "$PROGRAM" $((WANT - HAVE)) --url "$RPC_URL" --keypair "$DEPLOYER"
fi

say "Upgrade"
solana program deploy "$SO" \
  --url "$RPC_URL" --keypair "$DEPLOYER" \
  --program-id "$PROGRAM" --upgrade-authority "$DEPLOYER" \
  --with-compute-unit-price 10000 \
  --max-sign-attempts 50 --use-rpc
solana program show "$PROGRAM" --url "$RPC_URL"

say "init_stats (admin = deployer)"
RPC_URL=$RPC_URL node badge-test/wallet.mjs init-stats "$DEPLOYER"

say "Done"
echo "Leftover: $(solana balance "$ME" --url "$RPC_URL")"
