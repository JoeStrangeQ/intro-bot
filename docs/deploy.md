# Deploy intro_escrow to mainnet

Program id: `GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC`.
The program keypair lives at `~/.config/intro-bot/intro_escrow-keypair.json`, never in the repo.

## Plan

1. A hot "deployer" key deploys and runs `init_config` (it becomes admin).
2. Admin moves to the Ledger (admin can only pause new bids).
3. Upgrade authority moves to the Ledger.
4. After the checklist passes, the program is made immutable.

A Ledger can't comfortably sign the ~340 buffer writes or a custom Anchor instruction, so
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
   `idl/intro_escrow.json`. It creates `Config` and `Directory`.

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

## Pre-immutability checklist

- [ ] Deployed code matches the reviewed commit: `solana-verify` or
      `solana program dump <id> out.so` and compare hash with `target/deploy/intro_escrow.so`.
- [ ] `Config` exists: admin = Ledger, `paused = false`. `Directory` exists.
- [ ] Ledger can sign `set_paused` (test pause and unpause once).
- [ ] One full real job on mainnet with a small bid: register, bid, accept, made, confirm.
      Introer got the bid, requester got the rent back, request account closed.
- [ ] One refund path (withdraw or decline) works.
- [ ] Web app, Worker and badge point at this program id.
- [ ] IDL in repo matches the deployed build.
- [ ] Everyone agrees: no more code changes are possible after `--final`.

## Cost estimate (from the built .so, 339,216 bytes)

Rent = `(128 + bytes) × 6,960` lamports (same as `solana rent <bytes>`).

| Item | Bytes | SOL | Kept? |
| --- | --- | --- | --- |
| ProgramData (45 + .so, `--max-len` = .so size) | 339,261 | 2.3621 | locked forever once immutable |
| Program account | 36 | 0.0011 | locked |
| Buffer during deploy (37 + .so) | 339,253 | 2.3621 | returned after deploy |
| Deploy tx fees (~340 writes × 5,000 + priority) | | ~0.002–0.01 | spent |
| Config account | 74 | 0.0014 | locked |
| Directory account | 1,034 | 0.0081 | locked |
| Each introer (paid by introer) | 230 | 0.0025 | stays |
| Each request (paid by requester) | 210 | 0.0024 | returned to requester on settle |

Net cost: about **2.37 SOL**. Have about **4.8 SOL** in the deployer key during deploy, since
the buffer is funded before it is returned.
