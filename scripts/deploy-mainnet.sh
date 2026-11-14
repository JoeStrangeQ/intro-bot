#!/usr/bin/env bash
# Deploy intro_escrow to Solana mainnet and run init_config (docs/deploy.md).
# Then puts the relay live on mainnet. Keeps the upgrade authority on the deployer key; make it immutable later, by hand.
#
#   RPC_URL=<mainnet rpc> scripts/deploy-mainnet.sh
set -euo pipefail
cd "$(dirname "$0")/.."

KEYS=~/.config/intro-bot
DEPLOYER=$KEYS/deployer.json
PROGRAM_KEY=$KEYS/intro_escrow-keypair.json
PROGRAM=GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC
RPC_URL=${RPC_URL:-https://api.mainnet-beta.solana.com}
SO=target/deploy/intro_escrow.so
NEED_SOL=5.4

say() { printf '\n== %s\n' "$*"; }

[ -f "$DEPLOYER" ] || { echo "missing $DEPLOYER"; exit 1; }
[ -f "$PROGRAM_KEY" ] || { echo "missing $PROGRAM_KEY"; exit 1; }
[ "$(solana-keygen pubkey "$PROGRAM_KEY")" = "$PROGRAM" ] || { echo "program key mismatch"; exit 1; }

say "Build and test"
cargo build-sbf --manifest-path programs/intro-escrow/Cargo.toml --sbf-out-dir target/deploy
cargo test -q

say "Balance"
ME=$(solana-keygen pubkey "$DEPLOYER")
BAL=$(solana balance "$ME" --url "$RPC_URL" | awk '{print $1}')
echo "deployer $ME has $BAL SOL (needs ~$NEED_SOL)"
awk -v b="$BAL" -v n="$NEED_SOL" 'BEGIN { exit !(b >= n) }' || { echo "fund it first"; exit 1; }

if solana program show "$PROGRAM" --url "$RPC_URL" >/dev/null 2>&1; then
  say "Already deployed: skipping deploy"
else
  say "Deploy (max-len = .so size)"
  solana program deploy "$SO" \
    --url "$RPC_URL" --keypair "$DEPLOYER" \
    --program-id "$PROGRAM_KEY" \
    --max-len "$(stat -f%z "$SO")" \
    --with-compute-unit-price 10000 \
    --max-sign-attempts 50 --use-rpc
fi
solana program show "$PROGRAM" --url "$RPC_URL"

say "init_config (deployer becomes admin)"
RPC_URL=$RPC_URL node badge-test/wallet.mjs init-config "$DEPLOYER" \
  || echo "init_config failed (already done? check the Config account)"

say "Relay (relay.botbotcap.com, mainnet rpc)"
( cd services/relay
  printf '%s' "$RPC_URL" | npx -y wrangler@4 secret put RPC_URL --env production
  npx -y wrangler@4 deploy --env production )
curl -fsS -X POST https://relay.botbotcap.com/connect -H 'content-type: application/json' -d '{}' >/dev/null \
  && echo "relay is up" || echo "relay check failed"

say "Done"
echo "Program:   https://solscan.io/account/$PROGRAM"
echo "Authority: $ME (upgradable until you run --final)"
echo "Leftover:  $(solana balance "$ME" --url "$RPC_URL")"
