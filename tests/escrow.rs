//! LiteSVM tests for the intro escrow program. Build first: `cargo build-sbf`.
#![allow(clippy::unwrap_used, clippy::expect_used, reason = "tests")]
#![allow(
    clippy::unused_self,
    reason = "builders stay methods for one call style"
)]

use anchor_lang::{
    prelude::Pubkey,
    solana_program::{bpf_loader_upgradeable, instruction::Instruction},
    AccountDeserialize, InstructionData, ToAccountMetas,
};
use intro_escrow::{
    accounts as acc, instruction as ix, Config, Directory, Introer, OpenSlot, Request,
    CONFIRM_WINDOW, DIRECTORY_LEN, LAMPORTS_PER_SOL as SOL, MAX_BID, MAX_OFFER, MAX_OPEN,
    MAX_TARGET, MAX_TELEGRAM, MIN_BID_FLOOR, STATUS_ACCEPTED, STATUS_MADE, STATUS_OPEN,
    WITHDRAW_DELAY, WORK_WINDOW,
};
use litesvm::LiteSVM;
use solana_clock::Clock;
use solana_keypair::Keypair;
use solana_signer::Signer;
use solana_transaction::Transaction;

const PROGRAM: &str = "../target/deploy/intro_escrow.so";
const FEE: u64 = 5_000;
/// Half the default per-instruction budget of 200k CU.
const CU_LIMIT: u64 = 100_000;

struct T {
    svm: LiteSVM,
    admin: Keypair,
    config: Pubkey,
    /// Live requests, checked against their lamports and the open lists.
    live: Vec<Pubkey>,
}

fn program_data() -> Pubkey {
    Pubkey::find_program_address(&[intro_escrow::ID.as_ref()], &bpf_loader_upgradeable::ID).0
}

fn config_key() -> Pubkey {
    Pubkey::find_program_address(&[b"config"], &intro_escrow::ID).0
}

fn directory_key() -> Pubkey {
    Pubkey::find_program_address(&[b"directory"], &intro_escrow::ID).0
}

fn introer_key(wallet: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[b"introer", wallet.as_ref()], &intro_escrow::ID).0
}

fn request_key(introer: &Pubkey, id: u64) -> Pubkey {
    Pubkey::find_program_address(
        &[b"request", introer.as_ref(), &id.to_le_bytes()],
        &intro_escrow::ID,
    )
    .0
}

/// Zero-padded text field.
fn pad<const N: usize>(text: &str) -> [u8; N] {
    let mut out = [0; N];
    out[..text.len()].copy_from_slice(text.as_bytes());
    out
}

fn build(accounts: impl ToAccountMetas, data: impl InstructionData) -> Instruction {
    Instruction {
        program_id: intro_escrow::ID,
        accounts: accounts.to_account_metas(None),
        data: data.data(),
    }
}

/// Fresh chain with the program loaded and `authority` (if any) as the
/// upgrade authority in ProgramData.
/// Fails if the built program is older than its source, so tests never run
/// a stale `.so`. Rebuild with `cargo build-sbf` (or `anchor build`).
fn check_fresh_build() {
    static CHECKED: std::sync::Once = std::sync::Once::new();
    CHECKED.call_once(|| {
        let modified =
            |path: &std::path::Path| std::fs::metadata(path).and_then(|m| m.modified()).unwrap();
        let built = modified(std::path::Path::new(PROGRAM));
        let mut sources = vec![std::path::PathBuf::from(
            "../programs/intro-escrow/Cargo.toml",
        )];
        for entry in std::fs::read_dir("../programs/intro-escrow/src").unwrap() {
            sources.push(entry.unwrap().path());
        }
        for source in sources {
            assert!(
                modified(&source) <= built,
                "{PROGRAM} is older than {}: run `cargo build-sbf`",
                source.display()
            );
        }
    });
}

fn chain(authority: Option<Pubkey>) -> LiteSVM {
    check_fresh_build();
    let mut svm = LiteSVM::new();
    svm.add_program(intro_escrow::ID, &std::fs::read(PROGRAM).unwrap())
        .unwrap();
    if let Some(authority) = authority {
        let key = program_data();
        let mut account = svm.get_account(&key).unwrap();
        account.data[12] = 1;
        account.data[13..45].copy_from_slice(authority.as_ref());
        svm.set_account(key, account).unwrap();
    }
    svm
}

fn send(svm: &mut LiteSVM, payer: &Keypair, ix: Instruction) -> Result<(), String> {
    svm.expire_blockhash();
    let tx = Transaction::new_signed_with_payer(
        &[ix],
        Some(&payer.pubkey()),
        &[payer],
        svm.latest_blockhash(),
    );
    svm.send_transaction(tx)
        .map(|meta| {
            // The relay sends each action as one bare instruction, so it must
            // fit the default 200k CU budget with room to spare.
            assert!(
                meta.compute_units_consumed <= CU_LIMIT,
                "used {} CU",
                meta.compute_units_consumed
            );
        })
        .map_err(|e| format!("{:?} {}", e.err, e.meta.logs.join("\n")))
}

#[track_caller]
fn fails(result: Result<(), String>, code: &str) {
    let err = result.expect_err("expected failure");
    assert!(err.contains(code), "expected {code}, got: {err}");
}

#[track_caller]
fn fails_bid(result: Result<Pubkey, String>, code: &str) {
    fails(result.map(|_| ()), code);
}

fn init_config_ix(authority: Pubkey) -> Instruction {
    build(
        acc::InitConfig {
            authority,
            config: config_key(),
            directory: directory_key(),
            program: intro_escrow::ID,
            program_data: program_data(),
            system_program: anchor_lang::system_program::ID,
        },
        ix::InitConfig {},
    )
}

fn register_ix(wallet: Pubkey, offer: [u8; MAX_OFFER], min_bid: u64) -> Instruction {
    build(
        acc::RegisterIntroer {
            wallet,
            introer: introer_key(&wallet),
            directory: directory_key(),
            system_program: anchor_lang::system_program::ID,
        },
        ix::RegisterIntroer {
            badge_id: *b"BP26-001",
            offer,
            min_bid,
        },
    )
}

fn funded(svm: &mut LiteSVM, sol: u64) -> Keypair {
    let key = Keypair::new();
    svm.airdrop(&key.pubkey(), sol * SOL).unwrap();
    key
}

impl T {
    fn new() -> Self {
        Self::with_admin(Keypair::new())
    }

    fn with_admin(admin: Keypair) -> Self {
        let mut svm = chain(Some(admin.pubkey()));
        svm.airdrop(&admin.pubkey(), 10 * SOL).unwrap();
        send(&mut svm, &admin, init_config_ix(admin.pubkey())).unwrap();
        Self {
            svm,
            admin,
            config: config_key(),
            live: vec![],
        }
    }

    fn user(&mut self, sol: u64) -> Keypair {
        funded(&mut self.svm, sol)
    }

    fn lamports(&self, key: &Pubkey) -> u64 {
        self.svm.get_account(key).map_or(0, |a| a.lamports)
    }

    fn config(&self) -> Config {
        let data = self.svm.get_account(&self.config).unwrap().data;
        Config::try_deserialize(&mut data.as_slice()).unwrap()
    }

    fn directory(&self) -> Directory {
        let data = self.svm.get_account(&directory_key()).unwrap().data;
        Directory::try_deserialize(&mut data.as_slice()).unwrap()
    }

    fn introer(&self, wallet: &Pubkey) -> Introer {
        let data = self.svm.get_account(&introer_key(wallet)).unwrap().data;
        Introer::try_deserialize(&mut data.as_slice()).unwrap()
    }

    fn request(&self, key: &Pubkey) -> Request {
        let data = self.svm.get_account(key).unwrap().data;
        Request::try_deserialize(&mut data.as_slice()).unwrap()
    }

    fn gone(&self, key: &Pubkey) -> bool {
        self.svm.get_account(key).is_none_or(|a| a.lamports == 0)
    }

    fn warp(&mut self, seconds: i64) {
        let mut clock: Clock = self.svm.get_sysvar();
        clock.unix_timestamp += seconds;
        self.svm.set_sysvar(&clock);
    }

    /// Lamports held for bids: the sum of live bids.
    fn held(&self) -> u64 {
        self.live
            .iter()
            .filter(|k| !self.gone(k))
            .map(|k| self.request(k).bid)
            .sum()
    }

    fn now(&self) -> i64 {
        self.svm.get_sysvar::<Clock>().unix_timestamp
    }

    /// Each live request holds exactly rent + bid, and each introer's open
    /// list matches its open requests.
    fn check_books(&mut self) {
        let svm = &self.svm;
        self.live
            .retain(|key| svm.get_account(key).is_some_and(|a| a.lamports > 0));
        for key in &self.live {
            let account = self.svm.get_account(key).unwrap();
            let request = self.request(key);
            let rent = self
                .svm
                .minimum_balance_for_rent_exemption(account.data.len());
            assert_eq!(account.lamports, rent + request.bid, "request lamports");
        }
        // Each introer's open list matches its open requests.
        let mut introers: Vec<Pubkey> = vec![];
        for key in &self.live {
            let request = self.request(key);
            if !introers.contains(&request.introer) {
                introers.push(request.introer);
            }
        }
        for introer in introers {
            let data = self.svm.get_account(&introer).unwrap().data;
            let state = Introer::try_deserialize(&mut data.as_slice()).unwrap();
            let count = usize::from(state.open_count);
            let mut listed: Vec<OpenSlot> = state.open[..count].to_vec();
            assert!(state.open[count..]
                .iter()
                .all(|s| *s == OpenSlot::default()));
            let mut open: Vec<OpenSlot> = self
                .live
                .iter()
                .map(|k| self.request(k))
                .filter(|r| r.introer == introer && r.status == STATUS_OPEN)
                .map(|r| OpenSlot {
                    id: r.id,
                    bid: r.bid,
                })
                .collect();
            listed.sort_by_key(|s| s.id);
            open.sort_by_key(|s| s.id);
            assert_eq!(listed, open, "open slots");
        }
    }

    fn run(&mut self, payer: &Keypair, ix: Instruction) -> Result<(), String> {
        let result = send(&mut self.svm, payer, ix);
        self.check_books();
        result
    }

    fn register(&mut self, wallet: &Keypair, min_bid: u64) -> Result<(), String> {
        let ix = register_ix(wallet.pubkey(), pad("Solana founders in Lisbon"), min_bid);
        self.run(wallet, ix)
    }

    fn introer_with(&mut self, min_bid: u64) -> Keypair {
        let wallet = self.user(1);
        self.register(&wallet, min_bid).unwrap();
        wallet
    }

    fn bid_ix(
        &self,
        requester: &Pubkey,
        wallet: &Pubkey,
        amount: u64,
        lowest: Option<(Pubkey, Pubkey)>,
    ) -> Instruction {
        let introer = introer_key(wallet);
        let next = self
            .svm
            .get_account(&introer)
            .map_or(0, |_| self.introer(wallet).next_id);
        build(
            acc::Bid {
                requester: *requester,
                config: self.config,
                introer,
                request: request_key(&introer, next),
                system_program: anchor_lang::system_program::ID,
                lowest: lowest.map(|l| l.0),
                lowest_requester: lowest.map(|l| l.1),
            },
            ix::Bid {
                target: pad("Toly"),
                telegram: pad("@alice"),
                amount,
            },
        )
    }

    fn try_bid(
        &mut self,
        requester: &Keypair,
        wallet: &Pubkey,
        amount: u64,
        lowest: Option<(Pubkey, Pubkey)>,
    ) -> Result<Pubkey, String> {
        let key = request_key(&introer_key(wallet), self.introer(wallet).next_id);
        let ix = self.bid_ix(&requester.pubkey(), wallet, amount, lowest);
        send(&mut self.svm, requester, ix)?;
        self.live.push(key);
        self.check_books();
        Ok(key)
    }

    fn bid(&mut self, requester: &Keypair, wallet: &Pubkey, amount: u64) -> Pubkey {
        self.try_bid(requester, wallet, amount, None).unwrap()
    }

    fn step_ix(accept: bool, wallet: Pubkey, request: Pubkey) -> Instruction {
        let introer = introer_key(&wallet);
        if accept {
            build(
                acc::Accept {
                    wallet,
                    introer,
                    request,
                },
                ix::Accept {},
            )
        } else {
            build(
                acc::MarkMade {
                    wallet,
                    introer,
                    request,
                },
                ix::MarkMade {},
            )
        }
    }

    fn accept(&mut self, wallet: &Keypair, request: Pubkey) -> Result<(), String> {
        self.run(wallet, Self::step_ix(true, wallet.pubkey(), request))
    }

    fn made(&mut self, wallet: &Keypair, request: Pubkey) -> Result<(), String> {
        self.run(wallet, Self::step_ix(false, wallet.pubkey(), request))
    }

    fn withdraw_ix(&self, requester: Pubkey, wallet: &Pubkey, request: Pubkey) -> Instruction {
        build(
            acc::Withdraw {
                requester,
                introer: introer_key(wallet),
                request,
            },
            ix::Withdraw {},
        )
    }

    fn withdraw(
        &mut self,
        requester: &Keypair,
        wallet: &Pubkey,
        request: Pubkey,
    ) -> Result<(), String> {
        // Past the withdraw delay; `withdraw_waits_a_day` checks the delay.
        self.warp(WITHDRAW_DELAY);
        let ix = self.withdraw_ix(requester.pubkey(), wallet, request);
        self.run(requester, ix)
    }

    fn decline_ix(&self, wallet: Pubkey, request: Pubkey, requester: Pubkey) -> Instruction {
        build(
            acc::Decline {
                wallet,
                introer: introer_key(&wallet),
                request,
                requester,
            },
            ix::Decline {},
        )
    }

    fn decline(
        &mut self,
        wallet: &Keypair,
        request: Pubkey,
        requester: Pubkey,
    ) -> Result<(), String> {
        let ix = self.decline_ix(wallet.pubkey(), request, requester);
        self.run(wallet, ix)
    }

    fn confirm_ix(
        &self,
        introer: Pubkey,
        wallet: Pubkey,
        request: Pubkey,
        requester: Pubkey,
    ) -> Instruction {
        build(
            acc::Confirm {
                requester,
                introer,
                request,
                wallet,
            },
            ix::Confirm {},
        )
    }

    fn confirm(
        &mut self,
        requester: &Keypair,
        wallet: Pubkey,
        request: Pubkey,
    ) -> Result<(), String> {
        let ix = self.confirm_ix(introer_key(&wallet), wallet, request, requester.pubkey());
        self.run(requester, ix)
    }

    fn refund_ix(
        &self,
        unconfirmed: bool,
        caller: Pubkey,
        introer: Pubkey,
        request: Pubkey,
        requester: Pubkey,
    ) -> Instruction {
        let accounts = acc::RefundExpired {
            caller,
            introer,
            request,
            requester,
        };
        if unconfirmed {
            build(accounts, ix::RefundUnconfirmed {})
        } else {
            build(accounts, ix::RefundExpired {})
        }
    }

    fn refund_unconfirmed(
        &mut self,
        caller: &Keypair,
        wallet: Pubkey,
        request: Pubkey,
        requester: Pubkey,
    ) -> Result<(), String> {
        let ix = self.refund_ix(
            true,
            caller.pubkey(),
            introer_key(&wallet),
            request,
            requester,
        );
        self.run(caller, ix)
    }

    fn refund_expired(
        &mut self,
        caller: &Keypair,
        wallet: Pubkey,
        request: Pubkey,
        requester: Pubkey,
    ) -> Result<(), String> {
        let ix = self.refund_ix(
            false,
            caller.pubkey(),
            introer_key(&wallet),
            request,
            requester,
        );
        self.run(caller, ix)
    }

    fn admin_ix(&self, admin: Pubkey, data: impl InstructionData) -> Instruction {
        build(
            acc::AdminOnly {
                admin,
                config: self.config,
            },
            data,
        )
    }

    fn set_paused(&mut self, paused: bool) {
        let ix = self.admin_ix(self.admin.pubkey(), ix::SetPaused { paused });
        let admin = self.admin.insecure_clone();
        self.run(&admin, ix).unwrap();
    }

    /// Accepted and made request, ready to confirm.
    fn made_request(&mut self, amount: u64) -> (Keypair, Keypair, Pubkey) {
        let wallet = self.introer_with(MIN_BID_FLOOR);
        let requester = self.user(200);
        let request = self.bid(&requester, &wallet.pubkey(), amount);
        self.accept(&wallet, request).unwrap();
        self.made(&wallet, request).unwrap();
        (wallet, requester, request)
    }
}

// ---------- config ----------

#[test]
fn init_config_sets_upgrade_authority_as_admin() {
    let t = T::new();
    let config = t.config();
    assert_eq!(config.admin, t.admin.pubkey());
    assert!(!config.paused);
    let directory = t.directory();
    assert_eq!(directory.head, 0);
    assert!(directory.wallets.iter().all(|w| *w == Pubkey::default()));
}

#[test]
fn init_config_rejects_non_upgrade_authority() {
    let authority = Keypair::new();
    let mut svm = chain(Some(authority.pubkey()));
    let other = funded(&mut svm, 5);
    fails(
        send(&mut svm, &other, init_config_ix(other.pubkey())),
        "NotUpgradeAuthority",
    );
    assert!(svm.get_account(&config_key()).is_none());
}

#[test]
fn init_config_rejects_everyone_when_program_is_immutable() {
    let mut svm = chain(None);
    let other = funded(&mut svm, 5);
    fails(
        send(&mut svm, &other, init_config_ix(other.pubkey())),
        "NotUpgradeAuthority",
    );
}

#[test]
fn init_config_rejects_fake_program_data() {
    let authority = Keypair::new();
    let mut svm = chain(Some(authority.pubkey()));
    let attacker = funded(&mut svm, 5);
    // A ProgramData-shaped account naming the attacker, at another address.
    let fake = Pubkey::new_unique();
    let mut account = svm.get_account(&program_data()).unwrap();
    account.data[13..45].copy_from_slice(attacker.pubkey().as_ref());
    svm.set_account(fake, account).unwrap();
    let mut ix = init_config_ix(attacker.pubkey());
    ix.accounts[4].pubkey = fake;
    fails(send(&mut svm, &attacker, ix), "NotUpgradeAuthority");
}

#[test]
fn init_config_runs_only_once() {
    let mut t = T::new();
    let admin = t.admin.insecure_clone();
    assert!(send(&mut t.svm, &admin, init_config_ix(admin.pubkey())).is_err());
    assert_eq!(t.config().admin, admin.pubkey());
}

#[test]
fn admin_setters_work_and_reject_others() {
    let mut t = T::new();
    let admin = t.admin.insecure_clone();
    let stranger = t.user(1);
    let new_admin = t.user(1);
    let accept_ix = |config: Pubkey, signer: Pubkey| {
        build(
            acc::AcceptAdmin {
                pending_admin: signer,
                config,
            },
            ix::AcceptAdmin {},
        )
    };

    for ix in [
        t.admin_ix(stranger.pubkey(), ix::SetPaused { paused: true }),
        t.admin_ix(
            stranger.pubkey(),
            ix::ProposeAdmin {
                admin: stranger.pubkey(),
            },
        ),
    ] {
        fails(t.run(&stranger, ix), "Unauthorized");
    }
    // Nobody pending: accept fails for everyone.
    fails(
        t.run(&stranger, accept_ix(t.config, stranger.pubkey())),
        "Unauthorized",
    );
    // The default key can't be proposed.
    let ix = t.admin_ix(
        admin.pubkey(),
        ix::ProposeAdmin {
            admin: Pubkey::default(),
        },
    );
    fails(t.run(&admin, ix), "Unauthorized");

    let ix = t.admin_ix(admin.pubkey(), ix::SetPaused { paused: true });
    t.run(&admin, ix).unwrap();
    assert!(t.config().paused);
    let ix = t.admin_ix(
        admin.pubkey(),
        ix::ProposeAdmin {
            admin: new_admin.pubkey(),
        },
    );
    t.run(&admin, ix).unwrap();
    // Proposing alone changes nothing; only the proposed key can accept.
    assert_eq!(t.config().admin, admin.pubkey());
    assert_eq!(t.config().pending_admin, new_admin.pubkey());
    fails(
        t.run(&stranger, accept_ix(t.config, stranger.pubkey())),
        "Unauthorized",
    );
    t.run(&new_admin, accept_ix(t.config, new_admin.pubkey()))
        .unwrap();
    let config = t.config();
    assert_eq!(config.admin, new_admin.pubkey());
    assert_eq!(config.pending_admin, Pubkey::default());

    // The old admin is out, the new one is in.
    let ix = t.admin_ix(admin.pubkey(), ix::SetPaused { paused: false });
    fails(t.run(&admin, ix), "Unauthorized");
    let ix = t.admin_ix(new_admin.pubkey(), ix::SetPaused { paused: false });
    t.run(&new_admin, ix).unwrap();
    assert!(!t.config().paused);
}

#[test]
fn admin_setters_keep_working_after_program_is_made_immutable() {
    let mut t = T::new();
    let key = program_data();
    let mut account = t.svm.get_account(&key).unwrap();
    account.data[12] = 0;
    t.svm.set_account(key, account).unwrap();
    t.set_paused(true);
    assert!(t.config().paused);
}

// ---------- introer + directory ----------

#[test]
fn register_introer_stores_terms_and_lists_wallet() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR * 3);
    let introer = t.introer(&wallet.pubkey());
    assert_eq!(introer.wallet, wallet.pubkey());
    assert_eq!(&introer.badge_id, b"BP26-001");
    assert_eq!(introer.offer, pad("Solana founders in Lisbon"));
    assert_eq!(introer.min_bid, MIN_BID_FLOOR * 3);
    assert_eq!(introer.next_id, 0);
    assert_eq!(introer.open_count, 0);
    assert_eq!(introer.jobs_done, 0);
    assert_eq!(introer.created_at, t.now());
    let directory = t.directory();
    assert_eq!(directory.head, 1);
    assert_eq!(directory.wallets[0], wallet.pubkey());
    // Registering twice fails and leaves the directory alone.
    assert!(t.register(&wallet, MIN_BID_FLOOR).is_err());
    assert_eq!(t.directory().head, 1);
}

#[test]
fn directory_wraps_around() {
    let mut t = T::new();
    let mut wallets = vec![];
    for _ in 0..DIRECTORY_LEN + 3 {
        wallets.push(t.introer_with(MIN_BID_FLOOR).pubkey());
    }
    let directory = t.directory();
    assert_eq!(usize::from(directory.head), 3);
    // The 3 newest overwrote the 3 oldest.
    for (slot, wallet) in directory.wallets.iter().enumerate() {
        let expected = if slot < 3 {
            wallets[DIRECTORY_LEN + slot]
        } else {
            wallets[slot]
        };
        assert_eq!(*wallet, expected, "slot {slot}");
    }
}

#[test]
fn register_introer_checks_min_bid_and_offer() {
    let mut t = T::new();
    let wallet = t.user(1);
    fails(t.register(&wallet, MIN_BID_FLOOR - 1), "BidTooLow");
    fails(t.register(&wallet, MAX_BID + 1), "BidTooHigh");
    let mut bad = pad::<MAX_OFFER>("ab");
    bad[5] = b'x';
    fails(
        t.run(&wallet, register_ix(wallet.pubkey(), bad, MIN_BID_FLOOR)),
        "BadText",
    );
    let mut bad = pad::<MAX_OFFER>("ab");
    bad[0] = 0xff;
    fails(
        t.run(&wallet, register_ix(wallet.pubkey(), bad, MIN_BID_FLOOR)),
        "BadText",
    );
    let full = pad::<MAX_OFFER>(&"é".repeat(MAX_OFFER / 2));
    t.run(&wallet, register_ix(wallet.pubkey(), full, MIN_BID_FLOOR))
        .unwrap();
}

#[test]
fn update_introer_only_by_owner() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let stranger = t.user(1);
    let update = |signer: Pubkey, min_bid: u64| {
        build(
            acc::UpdateIntroer {
                wallet: signer,
                introer: introer_key(&wallet.pubkey()),
            },
            ix::UpdateIntroer {
                offer: pad("New offer"),
                min_bid,
            },
        )
    };
    assert!(t.run(&stranger, update(stranger.pubkey(), SOL)).is_err());
    fails(
        t.run(&wallet, update(wallet.pubkey(), MIN_BID_FLOOR - 1)),
        "BidTooLow",
    );
    t.run(&wallet, update(wallet.pubkey(), SOL)).unwrap();
    let introer = t.introer(&wallet.pubkey());
    assert_eq!(introer.min_bid, SOL);
    assert_eq!(introer.offer, pad("New offer"));
}

// ---------- happy path ----------

#[test]
fn happy_path_pays_introer_and_returns_rent() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(10);
    let bid = 2 * SOL;
    let before = t.lamports(&requester.pubkey());
    let request = t.bid(&requester, &wallet.pubkey(), bid);

    let stored = t.request(&request);
    assert_eq!(stored.introer, introer_key(&wallet.pubkey()));
    assert_eq!(stored.requester, requester.pubkey());
    assert_eq!(stored.id, 0);
    assert_eq!(stored.bid, bid);
    assert_eq!(stored.status, STATUS_OPEN);
    assert_eq!(stored.target, pad("Toly"));
    assert_eq!(stored.telegram, pad("@alice"));
    assert_eq!(stored.created_at, t.now());
    assert_eq!(t.introer(&wallet.pubkey()).open_count, 1);
    assert_eq!(t.introer(&wallet.pubkey()).next_id, 1);
    assert_eq!(t.held(), bid);

    t.warp(100);
    t.accept(&wallet, request).unwrap();
    let stored = t.request(&request);
    assert_eq!(stored.status, STATUS_ACCEPTED);
    assert_eq!(stored.accepted_at, t.now());
    assert_eq!(t.introer(&wallet.pubkey()).open_count, 0);

    t.warp(100);
    t.made(&wallet, request).unwrap();
    let stored = t.request(&request);
    assert_eq!(stored.status, STATUS_MADE);
    assert_eq!(stored.made_at, t.now());

    let wallet_before = t.lamports(&wallet.pubkey());
    t.confirm(&requester, wallet.pubkey(), request).unwrap();
    assert!(t.gone(&request));
    assert_eq!(t.lamports(&wallet.pubkey()), wallet_before + bid);
    // Requester is down only the bid and two tx fees: rent came back.
    assert_eq!(t.lamports(&requester.pubkey()), before - bid - 2 * FEE);
    let introer = t.introer(&wallet.pubkey());
    assert_eq!(introer.jobs_done, 1);
    assert_eq!(introer.earned, bid);
    assert_eq!(t.held(), 0);

    // A second job adds up.
    let request = t.bid(&requester, &wallet.pubkey(), SOL);
    assert_eq!(t.request(&request).id, 1);
    t.accept(&wallet, request).unwrap();
    t.confirm(&requester, wallet.pubkey(), request).unwrap();
    let introer = t.introer(&wallet.pubkey());
    assert_eq!(introer.jobs_done, 2);
    assert_eq!(introer.earned, 3 * SOL);
}

#[test]
fn confirm_works_from_accepted_but_not_open() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(10);
    let request = t.bid(&requester, &wallet.pubkey(), SOL);
    fails(t.confirm(&requester, wallet.pubkey(), request), "BadStatus");
    t.accept(&wallet, request).unwrap();
    t.confirm(&requester, wallet.pubkey(), request).unwrap();
    assert!(t.gone(&request));
}

// ---------- bid rules ----------

#[test]
fn bid_enforces_min_max_and_text() {
    let mut t = T::new();
    let wallet = t.introer_with(SOL);
    let requester = t.user(200);
    let w = wallet.pubkey();
    fails_bid(t.try_bid(&requester, &w, SOL - 1, None), "BidTooLow");
    fails_bid(t.try_bid(&requester, &w, MAX_BID + 1, None), "BidTooHigh");
    t.try_bid(&requester, &w, MAX_BID, None).unwrap();

    let text_bid = |t: &T, target: [u8; MAX_TARGET], telegram: [u8; MAX_TELEGRAM]| {
        let mut ix = t.bid_ix(&requester.pubkey(), &w, SOL, None);
        ix.data = ix::Bid {
            target,
            telegram,
            amount: SOL,
        }
        .data();
        ix
    };
    // Empty target.
    let ix = text_bid(&t, [0; MAX_TARGET], pad("@a"));
    fails(t.run(&requester, ix), "BadText");
    // Garbage after the padding.
    let mut target = pad("Toly");
    target[MAX_TARGET - 1] = b'x';
    let ix = text_bid(&t, target, pad("@a"));
    fails(t.run(&requester, ix), "BadText");
    // Not UTF-8.
    let mut telegram = pad("@a");
    telegram[1] = 0xc3;
    let ix = text_bid(&t, pad("Toly"), telegram);
    fails(t.run(&requester, ix), "BadText");
    // Empty handle.
    let ix = text_bid(&t, pad("Toly"), [0; MAX_TELEGRAM]);
    fails(t.run(&requester, ix), "BadText");
    // Full-length text is fine.
    let ix = text_bid(&t, [b'x'; MAX_TARGET], [b'y'; MAX_TELEGRAM]);
    t.live.push(request_key(&introer_key(&w), 1));
    t.run(&requester, ix).unwrap();
}

#[test]
fn bid_to_unknown_introer_fails() {
    let mut t = T::new();
    let requester = t.user(5);
    let nobody = Pubkey::new_unique();
    let ix = t.bid_ix(&requester.pubkey(), &nobody, SOL, None);
    assert!(t.run(&requester, ix).is_err());
}

#[test]
fn bid_with_wrong_request_id_fails() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(5);
    let mut ix = t.bid_ix(&requester.pubkey(), &wallet.pubkey(), SOL, None);
    ix.accounts[3].pubkey = request_key(&introer_key(&wallet.pubkey()), 7);
    assert!(t.run(&requester, ix).is_err());
}

#[test]
fn paused_blocks_bids_but_not_payouts_or_refunds() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(20);
    let w = wallet.pubkey();
    let r = requester.pubkey();
    let to_confirm = t.bid(&requester, &w, SOL);
    let to_withdraw = t.bid(&requester, &w, SOL);
    let to_decline = t.bid(&requester, &w, SOL);
    let unconfirmed = t.bid(&requester, &w, SOL);
    let expired = t.bid(&requester, &w, SOL);
    for request in [to_confirm, unconfirmed, expired] {
        t.accept(&wallet, request).unwrap();
    }
    t.made(&wallet, unconfirmed).unwrap();
    t.set_paused(true);

    fails_bid(t.try_bid(&requester, &w, SOL, None), "Paused");
    t.confirm(&requester, w, to_confirm).unwrap();
    t.withdraw(&requester, &w, to_withdraw).unwrap();
    t.decline(&wallet, to_decline, r).unwrap();
    t.warp(WORK_WINDOW + 1);
    let anyone = t.user(1);
    t.refund_unconfirmed(&anyone, w, unconfirmed, r).unwrap();
    t.refund_expired(&requester, w, expired, r).unwrap();
    assert_eq!(t.held(), 0);
    assert_eq!(t.introer(&w).jobs_done, 1);

    t.set_paused(false);
    t.bid(&requester, &w, SOL);
}

// ---------- full queue / outbid ----------

/// Introer with a full queue bidding 2, 1, 3, 4, 5 SOL: the lowest is [1].
fn full_queue(t: &mut T) -> (Keypair, Vec<(Keypair, Pubkey)>) {
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let mut open = vec![];
    for sol in [2, 1, 3, 4, 5] {
        let requester = t.user(10);
        let request = t.bid(&requester, &wallet.pubkey(), sol * SOL);
        open.push((requester, request));
    }
    assert_eq!(t.introer(&wallet.pubkey()).open_count, MAX_OPEN);
    (wallet, open)
}

#[test]
fn full_queue_needs_the_lowest_request() {
    let mut t = T::new();
    let (wallet, open) = full_queue(&mut t);
    let w = wallet.pubkey();
    let newcomer = t.user(10);
    fails_bid(t.try_bid(&newcomer, &w, 9 * SOL, None), "QueueFull");
    let lowest = Some((open[1].1, open[1].0.pubkey()));
    // Must beat the lowest by 10%.
    fails_bid(t.try_bid(&newcomer, &w, SOL, lowest), "BidTooLow");
    fails_bid(
        t.try_bid(&newcomer, &w, SOL + SOL / 10 - 1, lowest),
        "BidTooLow",
    );
    // Passing a request that is not the lowest fails.
    let not_lowest = Some((open[0].1, open[0].0.pubkey()));
    fails_bid(t.try_bid(&newcomer, &w, 9 * SOL, not_lowest), "NotLowest");
    // The refund must go to the stored requester.
    let swapped = Some((open[1].1, newcomer.pubkey()));
    fails_bid(t.try_bid(&newcomer, &w, 9 * SOL, swapped), "WrongRequester");
    // Nothing moved.
    assert_eq!(t.introer(&w).open_count, MAX_OPEN);
    assert_eq!(t.held(), 15 * SOL);
    // Exactly +10% is enough.
    t.try_bid(&newcomer, &w, SOL + SOL / 10, lowest).unwrap();
}

#[test]
fn outbid_refunds_and_closes_the_lowest() {
    let mut t = T::new();
    let (wallet, open) = full_queue(&mut t);
    let w = wallet.pubkey();
    let (loser, lowest) = (&open[1].0, open[1].1);
    let loser_before = t.lamports(&loser.pubkey());
    let lowest_lamports = t.lamports(&lowest);
    let newcomer = t.user(10);
    let request = t
        .try_bid(&newcomer, &w, 2 * SOL, Some((lowest, loser.pubkey())))
        .unwrap();
    assert!(t.gone(&lowest));
    assert_eq!(t.lamports(&loser.pubkey()), loser_before + lowest_lamports);
    assert_eq!(t.request(&request).bid, 2 * SOL);
    assert_eq!(t.introer(&w).open_count, MAX_OPEN);
    assert_eq!(t.held(), 16 * SOL);
    // The next lowest is now the oldest 2 SOL bid (a tie goes to the oldest).
    let next = t.introer(&w).lowest_open().unwrap();
    assert_eq!(next.id, t.request(&open[0].1).id);
    // The refunded request cannot be settled again.
    let ix = t.withdraw_ix(loser.pubkey(), &w, lowest);
    fails(t.run(loser, ix), "AccountNotInitialized");
}

#[test]
fn outbid_cannot_take_accepted_or_foreign_requests() {
    let mut t = T::new();
    let (wallet, open) = full_queue(&mut t);
    let w = wallet.pubkey();
    let other_wallet = t.introer_with(MIN_BID_FLOOR);
    let other_requester = t.user(5);
    let foreign = t.bid(&other_requester, &other_wallet.pubkey(), MIN_BID_FLOOR);
    let newcomer = t.user(30);
    // Another introer's request as the lowest.
    fails_bid(
        t.try_bid(
            &newcomer,
            &w,
            9 * SOL,
            Some((foreign, other_requester.pubkey())),
        ),
        "WrongRequest",
    );
    // Accept the lowest, then fill the slot again: the accepted request is no
    // longer listed, so it can't be passed as the lowest.
    t.accept(&wallet, open[1].1).unwrap();
    t.try_bid(&newcomer, &w, 2 * SOL, None).unwrap();
    let accepted = Some((open[1].1, open[1].0.pubkey()));
    fails_bid(t.try_bid(&newcomer, &w, 9 * SOL, accepted), "NotLowest");
    assert_eq!(t.request(&open[1].1).status, STATUS_ACCEPTED);
}

#[test]
fn requester_can_outbid_their_own_lowest_request() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let w = wallet.pubkey();
    let requester = t.user(30);
    let mut open = vec![];
    for sol in 1..=5 {
        open.push(t.bid(&requester, &w, sol * SOL));
    }
    let before = t.lamports(&requester.pubkey());
    let refund = t.lamports(&open[0]);
    let request = t
        .try_bid(&requester, &w, 6 * SOL, Some((open[0], requester.pubkey())))
        .unwrap();
    assert!(t.gone(&open[0]));
    let rent = t.lamports(&request) - 6 * SOL;
    assert_eq!(
        t.lamports(&requester.pubkey()),
        before + refund - 6 * SOL - rent - FEE
    );
}

#[test]
fn queue_near_max_bid_can_still_be_outbid() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let w = wallet.pubkey();
    let requester = t.user(600);
    let mut open = vec![];
    for sol in 91..=95 {
        open.push(t.bid(&requester, &w, sol * SOL));
    }
    // 110% of 91 SOL is above MAX_BID, so MAX_BID is enough.
    let lowest = Some((open[0], requester.pubkey()));
    fails_bid(t.try_bid(&requester, &w, MAX_BID - 1, lowest), "BidTooLow");
    t.try_bid(&requester, &w, MAX_BID, lowest).unwrap();
    // A full queue of MAX_BID bids can't be beaten.
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let w = wallet.pubkey();
    let rich = t.user(600);
    let mut open = vec![];
    for _ in 0..MAX_OPEN {
        open.push(t.bid(&rich, &w, MAX_BID));
    }
    fails_bid(
        t.try_bid(&requester, &w, MAX_BID, Some((open[0], rich.pubkey()))),
        "BidTooLow",
    );
}

#[test]
fn outbid_rounds_the_ten_percent_up() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let w = wallet.pubkey();
    let requester = t.user(30);
    // Lowest 0.010000001 SOL: 110% is 0.0110000011, rounded up to 11_000_002.
    let mut open = vec![t.bid(&requester, &w, MIN_BID_FLOOR + 1)];
    for _ in 1..MAX_OPEN {
        open.push(t.bid(&requester, &w, SOL));
    }
    let lowest = Some((open[0], requester.pubkey()));
    fails_bid(t.try_bid(&requester, &w, 11_000_001, lowest), "BidTooLow");
    t.try_bid(&requester, &w, 11_000_002, lowest).unwrap();
}

#[test]
fn introer_cannot_bid_on_themselves() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    fails_bid(t.try_bid(&wallet, &wallet.pubkey(), SOL, None), "SelfBid");
}

#[test]
fn lowest_is_ignored_when_queue_has_room() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let first = t.user(5);
    let request = t.bid(&first, &wallet.pubkey(), SOL);
    let second = t.user(5);
    t.try_bid(
        &second,
        &wallet.pubkey(),
        2 * SOL,
        Some((request, first.pubkey())),
    )
    .unwrap();
    assert_eq!(t.request(&request).status, STATUS_OPEN);
}

// ---------- withdraw / decline ----------

#[test]
fn withdraw_only_open_and_only_requester() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(10);
    let stranger = t.user(1);
    let w = wallet.pubkey();
    let request = t.bid(&requester, &w, SOL);
    fails(t.withdraw(&stranger, &w, request), "WrongRequester");
    let before = t.lamports(&requester.pubkey());
    let held = t.lamports(&request);
    t.withdraw(&requester, &w, request).unwrap();
    assert!(t.gone(&request));
    assert_eq!(t.lamports(&requester.pubkey()), before + held - FEE);
    assert_eq!(t.introer(&w).open_count, 0);

    let request = t.bid(&requester, &w, SOL);
    t.accept(&wallet, request).unwrap();
    fails(t.withdraw(&requester, &w, request), "BadStatus");
    t.made(&wallet, request).unwrap();
    fails(t.withdraw(&requester, &w, request), "BadStatus");
}

#[test]
fn withdraw_waits_a_day() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let w = wallet.pubkey();
    let requester = t.user(10);
    let request = t.bid(&requester, &w, SOL);
    t.warp(WITHDRAW_DELAY - 1);
    let ix = t.withdraw_ix(requester.pubkey(), &w, request);
    fails(t.run(&requester, ix), "TooEarly");
    t.warp(1);
    let ix = t.withdraw_ix(requester.pubkey(), &w, request);
    t.run(&requester, ix).unwrap();
    // Decline stays instant.
    let request = t.bid(&requester, &w, SOL);
    t.decline(&wallet, request, requester.pubkey()).unwrap();
}

#[test]
fn mark_made_only_within_the_work_window() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(10);
    let request = t.bid(&requester, &wallet.pubkey(), SOL);
    t.accept(&wallet, request).unwrap();
    t.warp(WORK_WINDOW + 1);
    fails(t.made(&wallet, request), "WorkExpired");
    // Exactly at the deadline still works.
    let request = t.bid(&requester, &wallet.pubkey(), SOL);
    t.accept(&wallet, request).unwrap();
    t.warp(WORK_WINDOW);
    t.made(&wallet, request).unwrap();
}

#[test]
fn withdraw_through_another_introer_fails() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let other = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(10);
    let request = t.bid(&requester, &wallet.pubkey(), SOL);
    // Would lower the wrong introer's open_count.
    assert!(t.withdraw(&requester, &other.pubkey(), request).is_err());
    assert_eq!(t.introer(&wallet.pubkey()).open_count, 1);
}

#[test]
fn decline_refunds_requester_and_only_by_introer() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(10);
    let request = t.bid(&requester, &wallet.pubkey(), SOL);
    let stranger = t.introer_with(MIN_BID_FLOOR);
    assert!(t.decline(&stranger, request, requester.pubkey()).is_err());
    fails(
        t.decline(&wallet, request, wallet.pubkey()),
        "WrongRequester",
    );
    let before = t.lamports(&requester.pubkey());
    let held = t.lamports(&request);
    t.decline(&wallet, request, requester.pubkey()).unwrap();
    assert_eq!(t.lamports(&requester.pubkey()), before + held);
    assert_eq!(t.introer(&wallet.pubkey()).open_count, 0);

    let request = t.bid(&requester, &wallet.pubkey(), SOL);
    t.accept(&wallet, request).unwrap();
    fails(t.decline(&wallet, request, requester.pubkey()), "BadStatus");
}

// ---------- introer steps ----------

#[test]
fn accept_and_made_need_the_introer_and_order() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(10);
    let request = t.bid(&requester, &wallet.pubkey(), SOL);
    let other = t.introer_with(MIN_BID_FLOOR);
    assert!(t.accept(&other, request).is_err());
    fails(t.made(&wallet, request), "BadStatus");
    t.accept(&wallet, request).unwrap();
    fails(t.accept(&wallet, request), "BadStatus");
    assert!(t.made(&other, request).is_err());
    t.made(&wallet, request).unwrap();
    fails(t.made(&wallet, request), "BadStatus");
}

// ---------- confirm / refunds ----------

#[test]
fn confirm_needs_the_requester() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(SOL);
    let w = wallet.pubkey();
    let stranger = t.user(1);
    let ix = t.confirm_ix(introer_key(&w), w, request, stranger.pubkey());
    fails(t.run(&stranger, ix), "WrongRequester");
    // The requester must sign: the introer can't confirm their own job.
    let mut ix = t.confirm_ix(introer_key(&w), w, request, requester.pubkey());
    ix.accounts[0].is_signer = false;
    assert!(t.run(&wallet, ix).is_err());
    t.confirm(&requester, w, request).unwrap();
}

#[test]
fn payout_destination_cannot_be_swapped() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(SOL);
    let w = wallet.pubkey();
    let r = requester.pubkey();
    let thief = t.user(1);
    let ix = t.confirm_ix(introer_key(&w), thief.pubkey(), request, r);
    fails(t.run(&requester, ix), "WrongWallet");
    // The thief's own introer PDA with the victim's request.
    t.register(&thief, MIN_BID_FLOOR).unwrap();
    let ix = t.confirm_ix(introer_key(&thief.pubkey()), thief.pubkey(), request, r);
    assert!(t.run(&requester, ix).is_err());
    assert_eq!(t.introer(&thief.pubkey()).jobs_done, 0);
    // Refund destinations are fixed too.
    t.warp(CONFIRM_WINDOW + 1);
    let ix = t.refund_ix(
        true,
        thief.pubkey(),
        introer_key(&w),
        request,
        thief.pubkey(),
    );
    fails(t.run(&thief, ix), "WrongRequester");
    let ix = t.refund_ix(
        true,
        thief.pubkey(),
        introer_key(&thief.pubkey()),
        request,
        r,
    );
    assert!(t.run(&thief, ix).is_err());
    let before = t.lamports(&w);
    t.confirm(&requester, w, request).unwrap();
    assert_eq!(t.lamports(&w), before + SOL);
}

#[test]
fn requester_can_still_confirm_after_the_window() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(SOL);
    t.warp(CONFIRM_WINDOW * 10);
    t.confirm(&requester, wallet.pubkey(), request).unwrap();
    assert_eq!(t.introer(&wallet.pubkey()).jobs_done, 1);
}

#[test]
fn refund_unconfirmed_waits_for_the_confirm_window() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(SOL);
    let (w, r) = (wallet.pubkey(), requester.pubkey());
    let anyone = t.user(1);
    t.warp(CONFIRM_WINDOW);
    fails(t.refund_unconfirmed(&anyone, w, request, r), "NotExpired");
    t.warp(1);
    let held = t.lamports(&request);
    let requester_before = t.lamports(&r);
    let wallet_before = t.lamports(&w);
    t.refund_unconfirmed(&anyone, w, request, r).unwrap();
    assert!(t.gone(&request));
    assert_eq!(t.lamports(&w), wallet_before);
    assert_eq!(t.lamports(&r), requester_before + held);
    assert_eq!(t.introer(&w).jobs_done, 0);
    // Double settle is impossible.
    assert!(t.refund_unconfirmed(&anyone, w, request, r).is_err());
    assert!(t.confirm(&requester, w, request).is_err());
    assert_eq!(t.introer(&w).jobs_done, 0);
}

#[test]
fn refund_unconfirmed_needs_made() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let w = wallet.pubkey();
    let requester = t.user(10);
    let r = requester.pubkey();
    let anyone = t.user(1);
    let request = t.bid(&requester, &w, SOL);
    t.warp(WORK_WINDOW * 2);
    fails(t.refund_unconfirmed(&anyone, w, request, r), "BadStatus");
    t.accept(&wallet, request).unwrap();
    t.warp(WORK_WINDOW * 2);
    fails(t.refund_unconfirmed(&anyone, w, request, r), "BadStatus");
}

#[test]
fn refund_expired_waits_for_the_work_window() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let w = wallet.pubkey();
    let requester = t.user(10);
    let r = requester.pubkey();
    let anyone = t.user(1);
    let request = t.bid(&requester, &w, SOL);
    fails(t.refund_expired(&requester, w, request, r), "BadStatus");
    t.accept(&wallet, request).unwrap();
    t.warp(WORK_WINDOW);
    fails(t.refund_expired(&requester, w, request, r), "NotExpired");
    t.warp(1);
    // Only the requester may refund right after the work window.
    fails(t.refund_expired(&anyone, w, request, r), "NotExpired");
    fails(
        t.refund_expired(&anyone, w, request, anyone.pubkey()),
        "WrongRequester",
    );
    let before = t.lamports(&r);
    let held = t.lamports(&request);
    t.refund_expired(&requester, w, request, r).unwrap();
    assert_eq!(t.lamports(&r), before + held - FEE);
    assert_eq!(t.introer(&w).jobs_done, 0);
    assert!(t.refund_expired(&requester, w, request, r).is_err());
}

#[test]
fn others_refund_expired_only_after_the_confirm_grace() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let w = wallet.pubkey();
    let requester = t.user(10);
    let r = requester.pubkey();
    let anyone = t.user(1);
    let request = t.bid(&requester, &w, SOL);
    t.accept(&wallet, request).unwrap();
    t.warp(WORK_WINDOW + CONFIRM_WINDOW);
    fails(t.refund_expired(&anyone, w, request, r), "NotExpired");
    // Meanwhile a late confirm still pays the introer.
    let late = t.bid(&requester, &w, SOL);
    t.accept(&wallet, late).unwrap();
    t.warp(1);
    let before = t.lamports(&r);
    let held = t.lamports(&request);
    t.refund_expired(&anyone, w, request, r).unwrap();
    assert_eq!(t.lamports(&r), before + held);
    t.warp(WORK_WINDOW * 3);
    t.confirm(&requester, w, late).unwrap();
    assert_eq!(t.introer(&w).jobs_done, 1);
}

#[test]
fn refund_expired_does_not_apply_once_made() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(SOL);
    t.warp(WORK_WINDOW * 2);
    fails(
        t.refund_expired(&requester, wallet.pubkey(), request, requester.pubkey()),
        "BadStatus",
    );
}

// ---------- lamport accounting ----------

#[test]
fn extra_lamports_sent_to_a_request_go_back_to_requester() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(SOL);
    let (w, r) = (wallet.pubkey(), requester.pubkey());
    // Someone tops up the request account directly.
    let donor = t.user(2);
    let ix =
        anchor_lang::solana_program::system_instruction::transfer(&donor.pubkey(), &request, SOL);
    send(&mut t.svm, &donor, ix).unwrap();
    let held = t.lamports(&request);
    let wallet_before = t.lamports(&w);
    let requester_before = t.lamports(&r);
    t.live.clear();
    t.confirm(&requester, w, request).unwrap();
    // The introer gets exactly the bid; the rest goes back to the requester.
    assert_eq!(t.lamports(&w), wallet_before + SOL);
    assert_eq!(t.lamports(&r), requester_before + held - SOL - FEE);
    assert_eq!(t.held(), 0);
}

#[test]
fn many_requests_keep_books_balanced() {
    let mut t = T::new();
    let a = t.introer_with(MIN_BID_FLOOR);
    let b = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(200);
    let r = requester.pubkey();
    let r1 = t.bid(&requester, &a.pubkey(), SOL);
    let r2 = t.bid(&requester, &b.pubkey(), 2 * SOL);
    let r3 = t.bid(&requester, &a.pubkey(), 3 * SOL);
    let r4 = t.bid(&requester, &b.pubkey(), 4 * SOL);
    assert_eq!(t.held(), 10 * SOL);
    // Requests of one introer can't be driven through the other.
    assert!(t.accept(&b, r1).is_err());
    assert!(t.decline(&a, r2, r).is_err());
    t.accept(&a, r1).unwrap();
    t.confirm(&requester, a.pubkey(), r1).unwrap();
    t.decline(&b, r2, r).unwrap();
    t.withdraw(&requester, &a.pubkey(), r3).unwrap();
    t.accept(&b, r4).unwrap();
    t.made(&b, r4).unwrap();
    t.warp(CONFIRM_WINDOW + 1);
    let anyone = t.user(1);
    t.refund_unconfirmed(&anyone, b.pubkey(), r4, r).unwrap();
    assert_eq!(t.held(), 0);
    assert_eq!(t.introer(&a.pubkey()).earned, SOL);
    assert_eq!(t.introer(&b.pubkey()).earned, 0);
    assert_eq!(t.introer(&a.pubkey()).open_count, 0);
    assert_eq!(t.introer(&b.pubkey()).open_count, 0);
    assert!(t.live.is_empty());
}

#[test]
fn request_ids_are_never_reused() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(10);
    let r0 = t.bid(&requester, &wallet.pubkey(), SOL);
    t.withdraw(&requester, &wallet.pubkey(), r0).unwrap();
    let r1 = t.bid(&requester, &wallet.pubkey(), SOL);
    assert_ne!(r0, r1);
    assert_eq!(t.request(&r1).id, 1);
}

#[test]
fn constants_match_spec() {
    assert_eq!(MAX_BID, 100 * SOL);
    assert_eq!(MIN_BID_FLOOR, 10_000_000);
    assert_eq!(MAX_OPEN, 5);
    assert_eq!(CONFIRM_WINDOW, 72 * 3600);
    assert_eq!(WORK_WINDOW, 7 * 86_400);
    assert_eq!(STATUS_MADE, 2);
}

// ---------- fixed layouts + fixtures for the badge ----------

fn u64_at(data: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(data[at..at + 8].try_into().unwrap())
}

/// Byte offsets documented in docs/spec.md; the badge decodes these in Lua.
#[test]
fn account_layouts_have_fixed_offsets() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let w = wallet.pubkey();
    let requester = t.user(10);
    let request = t.bid(&requester, &w, 2 * SOL);
    t.accept(&wallet, request).unwrap();

    let data = t.svm.get_account(&config_key()).unwrap().data;
    assert_eq!(data.len(), 74);
    assert_eq!(&data[8..40], t.admin.pubkey().as_ref());
    assert!(data[40..72].iter().all(|b| *b == 0)); // pending_admin
    assert_eq!(data[72], 0); // paused
    assert_eq!(data[73], t.config().bump);

    let data = t.svm.get_account(&introer_key(&w)).unwrap().data;
    assert_eq!(data.len(), 230);
    assert_eq!(&data[8..40], w.as_ref());
    assert_eq!(u64_at(&data, 40), MIN_BID_FLOOR);
    assert_eq!(u64_at(&data, 48), 1); // next_id
    assert_eq!(&data[56..60], &0u32.to_le_bytes()); // jobs_done
    assert_eq!(u64_at(&data, 60), 0); // earned
    assert_eq!(u64_at(&data, 68) as i64, t.introer(&w).created_at);
    assert_eq!(data[76], 0); // open_count
    assert_eq!(data[77], t.introer(&w).bump);
    assert_eq!(&data[78..86], b"BP26-001");
    assert_eq!(&data[86..150], &pad::<64>("Solana founders in Lisbon"));
    // open: 5 × (id u64, bid u64) from 150. Request 0 was accepted, 1 is open.
    let request_1 = t.bid(&requester, &w, 3 * SOL);
    let data = t.svm.get_account(&introer_key(&w)).unwrap().data;
    assert_eq!(data[76], 1);
    assert_eq!(u64_at(&data, 150), 1);
    assert_eq!(u64_at(&data, 158), 3 * SOL);
    assert!(data[166..230].iter().all(|b| *b == 0));
    assert_eq!(t.request(&request_1).id, 1);

    let data = t.svm.get_account(&request).unwrap().data;
    assert_eq!(data.len(), 210);
    assert_eq!(&data[8..40], introer_key(&w).as_ref());
    assert_eq!(&data[40..72], requester.pubkey().as_ref());
    assert_eq!(u64_at(&data, 72), 0); // id
    assert_eq!(u64_at(&data, 80), 2 * SOL);
    assert_eq!(data[88], STATUS_ACCEPTED);
    assert_eq!(u64_at(&data, 89) as i64, t.request(&request).created_at);
    assert_eq!(u64_at(&data, 97) as i64, t.now()); // accepted_at
    assert_eq!(u64_at(&data, 105), 0); // made_at
    assert_eq!(data[113], t.request(&request).bump);
    assert_eq!(&data[114..178], &pad::<64>("Toly"));
    assert_eq!(&data[178..210], &pad::<32>("@alice"));

    let data = t.svm.get_account(&directory_key()).unwrap().data;
    assert_eq!(data.len(), 8 + 2 + 32 * DIRECTORY_LEN);
    assert_eq!(data[8], 1);
    assert_eq!(data[9], t.directory().bump);
    assert_eq!(&data[10..42], w.as_ref());
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes.iter().fold(String::new(), |mut out, b| {
        write!(out, "{b:02x}").unwrap();
        out
    })
}

fn fixture(name: &str, ix: &Instruction) -> String {
    let accounts: Vec<String> = ix
        .accounts
        .iter()
        .map(|m| {
            format!(
                "    {{ \"pubkey\": \"{}\", \"signer\": {}, \"writable\": {} }}",
                m.pubkey, m.is_signer, m.is_writable
            )
        })
        .collect();
    format!(
        "{{\n  \"name\": \"{name}\",\n  \"program_id\": \"{}\",\n  \"accounts\": [\n{}\n  ],\n  \"data_hex\": \"{}\"\n}}\n",
        ix.program_id,
        accounts.join(",\n"),
        hex(&ix.data)
    )
}

/// Writes one instruction per file to `tests/fixtures/`, built from fixed
/// keys, after checking each one runs. The badge's Lua encoders are compared
/// against these. Account dumps go to `tests/fixtures/accounts.json`.
#[test]
fn write_instruction_fixtures() {
    let key = |n: u8| Keypair::new_from_array([n; 32]);
    let (admin, wallet, requester) = (key(1), key(2), key(3));
    let mut t = T::with_admin(admin.insecure_clone());
    let mut clock: Clock = t.svm.get_sysvar();
    clock.unix_timestamp = 1_790_000_000;
    t.svm.set_sysvar(&clock);
    for k in [&wallet, &requester] {
        t.svm.airdrop(&k.pubkey(), 30 * SOL).unwrap();
    }
    let (w, r) = (wallet.pubkey(), requester.pubkey());
    let introer = introer_key(&w);
    let req = |id| request_key(&introer, id);
    let mut out: Vec<(&str, Instruction)> = vec![];
    let mut go = |t: &mut T, name: &'static str, payer: &Keypair, ix: Instruction| {
        t.run(payer, ix.clone()).unwrap();
        out.push((name, ix));
    };
    let bid_more = |t: &mut T, sol: u64| {
        let id = t.introer(&w).next_id;
        let ix = t.bid_ix(&r, &w, sol * SOL, None);
        t.live.push(req(id));
        t.run(&requester, ix).unwrap();
    };

    let ix = register_ix(w, pad("Solana founders in Lisbon"), MIN_BID_FLOOR);
    go(&mut t, "register_introer", &wallet, ix);
    let ix = build(
        acc::UpdateIntroer { wallet: w, introer },
        ix::UpdateIntroer {
            offer: pad("Solana founders"),
            min_bid: MIN_BID_FLOOR,
        },
    );
    go(&mut t, "update_introer", &wallet, ix);
    let ix = t.bid_ix(&r, &w, SOL, None);
    t.live.push(req(0));
    go(&mut t, "bid", &requester, ix);
    go(&mut t, "accept", &wallet, T::step_ix(true, w, req(0)));
    go(&mut t, "mark_made", &wallet, T::step_ix(false, w, req(0)));
    let ix = t.confirm_ix(introer, w, req(0), r);
    go(&mut t, "confirm", &requester, ix);
    bid_more(&mut t, 1);
    bid_more(&mut t, 1);
    t.warp(WITHDRAW_DELAY);
    let ix = t.withdraw_ix(r, &w, req(1));
    go(&mut t, "withdraw", &requester, ix);
    let ix = t.decline_ix(w, req(2), r);
    go(&mut t, "decline", &wallet, ix);
    bid_more(&mut t, 1);
    bid_more(&mut t, 1);
    t.accept(&wallet, req(3)).unwrap();
    t.made(&wallet, req(3)).unwrap();
    t.accept(&wallet, req(4)).unwrap();
    t.warp(WORK_WINDOW + 1);
    let ix = t.refund_ix(true, w, introer, req(3), r);
    go(&mut t, "refund_unconfirmed", &wallet, ix);
    let ix = t.refund_ix(false, r, introer, req(4), r);
    go(&mut t, "refund_expired", &requester, ix);
    // Full queue: bids 1..=5 SOL (ids 5..=9); outbid the 1 SOL one.
    for sol in 1..=5 {
        bid_more(&mut t, sol);
    }
    let ix = t.bid_ix(&r, &w, 6 * SOL, Some((req(5), r)));
    t.live.push(req(10));
    go(&mut t, "bid_outbid", &requester, ix);
    let ix = t.admin_ix(admin.pubkey(), ix::SetPaused { paused: false });
    go(&mut t, "set_paused", &admin, ix);
    let ix = t.admin_ix(admin.pubkey(), ix::ProposeAdmin { admin: w });
    go(&mut t, "propose_admin", &admin, ix);
    let ix = build(
        acc::AcceptAdmin {
            pending_admin: w,
            config: config_key(),
        },
        ix::AcceptAdmin {},
    );
    go(&mut t, "accept_admin", &wallet, ix);

    let dir = std::path::Path::new("fixtures");
    std::fs::create_dir_all(dir).unwrap();
    for (name, ix) in &out {
        std::fs::write(dir.join(format!("{name}.json")), fixture(name, ix)).unwrap();
    }
    let dump = |key: Pubkey| {
        let data = t.svm.get_account(&key).unwrap().data;
        format!(
            "{{ \"pubkey\": \"{key}\", \"data_hex\": \"{}\" }}",
            hex(&data)
        )
    };
    let accounts = format!(
        "{{\n  \"config\": {},\n  \"directory\": {},\n  \"introer\": {},\n  \"request\": {}\n}}\n",
        dump(config_key()),
        dump(directory_key()),
        dump(introer),
        dump(req(10)),
    );
    std::fs::write(dir.join("accounts.json"), accounts).unwrap();
}
