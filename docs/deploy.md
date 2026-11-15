# Deploy intro_escrow to mainnet

Program id: `GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC`.
The program keypair lives at `~/.config/intro-bot/intro_escrow-keypair.json`, never in the repo.

## Plan

1. A hot "deployer" key deploys and runs `init_config` (it becomes admin).
2. Admin moves to the Ledger (admin can only pause `post_job` and `offer`; payouts and refunds never pause).
3. Upgrade authority moves to the Ledger.
4. After the checklist passes, the program is made immutable.

A Ledger can't comfortably sign the ~350 buffer writes or a custom Anchor instruction, so
the hot key does those, then hands everything to the Ledger.

## Steps

```sh
# 0. Build and test
anchor build            # or: cargo build-sbf
cargo test && cargo clippy --all-targets -- -D warnings
ls -l target/deploy/intro_escrow.so           # note the size, used as --max-len
cp ~/.config/intro-bot/intro_escrow-keypair.json target/deploy/

# 1. Fund a fresh hot key with ~5 SOL (see costs)
solana-keygen new -o ~/.config/intro-bot/deployer.json
solana config set --url mainnet-beta --keypair ~/.config/intro-bot/deployer.json
LEDGER=$(solana-keygen pubkey usb://ledger)

# 2. Deploy, max-len = .so size (it becomes immutable, no room needed)
solana program deploy target/deploy/intro_escrow.so \
  --program-id ~/.config/intro-bot/intro_escrow-keypair.json \
  --max-len $(stat -f%z target/deploy/intro_escrow.so) \
  --with-compute-unit-price 10000
```

3. Run `init_config()` signed by the deployer key, e.g. with the Anchor TS client and
   `idl/intro_escrow.json`. It creates `Config` and `Board`.

4. `propose_admin(<LEDGER>)`, signed by the deployer, then `accept_admin`, signed by the
   Ledger. Check the `Config` bytes (`solana account <config PDA>`): admin at offset 8 is the
   Ledger, pending_admin (offset 40) is zeros.

```sh
# 5. Upgrade authority to the Ledger
solana program set-upgrade-authority GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC \
  --new-upgrade-authority $LEDGER --skip-new-upgrade-authority-signer-check
solana program show GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC   # Authority = Ledger

# 6. Run the checklist below, then make it immutable (cannot be undone)
solana program set-upgrade-authority GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC \
  --final --upgrade-authority usb://ledger
```

If a deploy fails midway, `solana program show --buffers` lists the buffer; close it with
`solana program close <buffer>` to get its SOL back.

## Upgrade (before `--final`)

`scripts/upgrade-mainnet.sh` builds and tests, grows the program account if the new build is
bigger (`solana program extend`), upgrades with the deployer key, then runs `init_stats`
(admin only; skipped if `Stats` exists). It reads the RPC from `~/.config/intro-bot/rpc-url`.
Needs ~2.2 SOL: the ~2.0 SOL buffer comes back, ~0.1 SOL stays as rent for the extra bytes.

## Pre-immutability checklist

- [ ] Deployed code matches the reviewed commit: `solana-verify` or
      `solana program dump <id> out.so` and compare hash with `target/deploy/intro_escrow.so`.
- [ ] `Config` exists: admin = Ledger, `paused = false`. `Board` and `Stats` exist.
- [ ] Ledger can sign `set_paused` (test pause and unpause once).
- [ ] One full real job on mainnet with a small bid: register, post_job, offer, approve,
      mark_made, confirm. Introer got the bid, requester got the rent back, job closed,
      `close_offer` returned the offer rent.
- [ ] One refund path (`cancel_job`) works.
- [ ] Web app, Worker and badge point at this program id.
- [ ] IDL in repo matches the deployed build.
- [ ] Everyone agrees: no more code changes are possible after `--final`.

## Cost estimate (from the built .so, 346,536 bytes)

Rent = `(128 + bytes) × 6,960` lamports (same as `solana rent <bytes>`).

| Item | Bytes | SOL | Kept? |
| --- | --- | --- | --- |
| ProgramData (45 + .so, `--max-len` = .so size) | 346,581 | 2.4131 | locked forever once immutable |
| Program account | 36 | 0.0011 | locked |
| Buffer during deploy (37 + .so) | 346,573 | 2.4131 | returned after deploy |
| Deploy tx fees (~350 writes × 5,000 + priority) | | ~0.002–0.01 | spent |
| Config account | 74 | 0.0014 | locked |
| Board account | 2,072 | 0.0153 | locked |
| Each introer (paid by introer) | 101 | 0.0016 | stays |
| Each job (paid by requester) | 733 | 0.0060 | returned to requester on settle |
| Each offer (paid by introer) | 89 | 0.0015 | returned to introer when closed |

Net cost: about **2.43 SOL**. Have about **4.9 SOL** in the deployer key during deploy, since
the buffer is funded before it is returned.
