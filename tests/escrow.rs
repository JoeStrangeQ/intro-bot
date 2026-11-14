//! LiteSVM tests for the intro escrow program. Build first: `cargo build-sbf`.
#![allow(clippy::unwrap_used, clippy::expect_used, reason = "tests")]

use anchor_lang::{
    prelude::Pubkey,
    solana_program::{
        bpf_loader_upgradeable,
        instruction::{AccountMeta, Instruction},
    },
    AccountDeserialize, InstructionData, ToAccountMetas,
};
use intro_escrow::{
    accounts as acc, instruction as ix, Config, Introer, Request, CONFIRM_WINDOW,
    LAMPORTS_PER_SOL as SOL, MAX_BID, MAX_OPEN, MIN_BID_FLOOR, STATUS_ACCEPTED, STATUS_DISPUTED,
    STATUS_MADE, STATUS_OPEN, WORK_WINDOW,
};
use litesvm::LiteSVM;
use solana_clock::Clock;
use solana_keypair::Keypair;
use solana_signer::Signer;
use solana_transaction::Transaction;

const PROGRAM: &str = "../target/deploy/intro_escrow.so";
const CAP: u64 = 1_000 * SOL;
const FEE: u64 = 5_000;

struct T {
    svm: LiteSVM,
    admin: Keypair,
    arbiter: Keypair,
    config: Pubkey,
    /// Live requests, checked against `total_held` and their lamports.
    live: Vec<Pubkey>,
}

fn program_data() -> Pubkey {
    Pubkey::find_program_address(&[intro_escrow::ID.as_ref()], &bpf_loader_upgradeable::ID).0
}

fn config_key() -> Pubkey {
    Pubkey::find_program_address(&[b"config"], &intro_escrow::ID).0
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

fn build(accounts: impl ToAccountMetas, data: impl InstructionData) -> Instruction {
    Instruction {
        program_id: intro_escrow::ID,
        accounts: accounts.to_account_metas(None),
        data: data.data(),
    }
}

/// Fresh chain with the program loaded and `authority` (if any) as the
/// upgrade authority in ProgramData.
fn chain(authority: Option<Pubkey>) -> LiteSVM {
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
        .map(|_| ())
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

fn init_config_ix(authority: Pubkey, arbiter: Pubkey, cap_total: u64) -> Instruction {
    build(
        acc::InitConfig {
            config: config_key(),
            authority,
            program: intro_escrow::ID,
            program_data: program_data(),
            system_program: anchor_lang::system_program::ID,
        },
        ix::InitConfig { arbiter, cap_total },
    )
}

fn funded(svm: &mut LiteSVM, sol: u64) -> Keypair {
    let key = Keypair::new();
    svm.airdrop(&key.pubkey(), sol * SOL).unwrap();
    key
}

impl T {
    fn new() -> Self {
        Self::with_cap(CAP)
    }

    fn with_cap(cap: u64) -> Self {
        let admin = Keypair::new();
        let mut svm = chain(Some(admin.pubkey()));
        svm.airdrop(&admin.pubkey(), 10 * SOL).unwrap();
        let arbiter = funded(&mut svm, 1);
        send(
            &mut svm,
            &admin,
            init_config_ix(admin.pubkey(), arbiter.pubkey(), cap),
        )
        .unwrap();
        Self {
            svm,
            admin,
            arbiter,
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

    fn now(&self) -> i64 {
        self.svm.get_sysvar::<Clock>().unix_timestamp
    }

    /// `total_held` equals the sum of live bids, and each live request holds
    /// exactly rent + bid.
    fn check_books(&mut self) {
        let svm = &self.svm;
        self.live
            .retain(|key| svm.get_account(key).is_some_and(|a| a.lamports > 0));
        let mut sum = 0;
        for key in &self.live {
            let account = self.svm.get_account(key).unwrap();
            let request = self.request(key);
            let rent = self
                .svm
                .minimum_balance_for_rent_exemption(account.data.len());
            assert_eq!(account.lamports, rent + request.bid, "request lamports");
            sum += request.bid;
        }
        assert_eq!(self.config().total_held, sum, "total_held");
    }

    fn run(&mut self, payer: &Keypair, ix: Instruction) -> Result<(), String> {
        let result = send(&mut self.svm, payer, ix);
        self.check_books();
        result
    }

    fn register(&mut self, wallet: &Keypair, min_bid: u64) -> Result<(), String> {
        let ix = build(
            acc::RegisterIntroer {
                introer: introer_key(&wallet.pubkey()),
                wallet: wallet.pubkey(),
                system_program: anchor_lang::system_program::ID,
            },
            ix::RegisterIntroer {
                badge_id: *b"BP26-001",
                offer: "Solana founders in Lisbon".into(),
                min_bid,
            },
        );
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
        others: &[Pubkey],
    ) -> Instruction {
        let introer = introer_key(wallet);
        let next = self
            .svm
            .get_account(&introer)
            .map_or(0, |_| self.introer(wallet).next_id);
        let mut ix = build(
            acc::Bid {
                config: self.config,
                introer,
                request: request_key(&introer, next),
                requester: *requester,
                lowest: lowest.map(|l| l.0),
                lowest_requester: lowest.map(|l| l.1),
                system_program: anchor_lang::system_program::ID,
            },
            ix::Bid {
                target: "Toly".into(),
                telegram: "@alice".into(),
                amount,
            },
        );
        ix.accounts
            .extend(others.iter().map(|k| AccountMeta::new_readonly(*k, false)));
        ix
    }

    fn try_bid(
        &mut self,
        requester: &Keypair,
        wallet: &Pubkey,
        amount: u64,
        lowest: Option<(Pubkey, Pubkey)>,
        others: &[Pubkey],
    ) -> Result<Pubkey, String> {
        let key = request_key(&introer_key(wallet), self.introer(wallet).next_id);
        let ix = self.bid_ix(&requester.pubkey(), wallet, amount, lowest, others);
        send(&mut self.svm, requester, ix)?;
        self.live.push(key);
        self.check_books();
        Ok(key)
    }

    fn bid(&mut self, requester: &Keypair, wallet: &Pubkey, amount: u64) -> Pubkey {
        self.try_bid(requester, wallet, amount, None, &[]).unwrap()
    }

    fn step(&mut self, accept: bool, wallet: &Keypair, request: Pubkey) -> Result<(), String> {
        let accounts = acc::IntroerStep {
            introer: introer_key(&wallet.pubkey()),
            request,
            wallet: wallet.pubkey(),
        };
        let ix = if accept {
            build(accounts, ix::Accept {})
        } else {
            build(accounts, ix::MarkMade {})
        };
        self.run(wallet, ix)
    }

    fn accept(&mut self, wallet: &Keypair, request: Pubkey) -> Result<(), String> {
        self.step(true, wallet, request)
    }

    fn made(&mut self, wallet: &Keypair, request: Pubkey) -> Result<(), String> {
        self.step(false, wallet, request)
    }

    fn withdraw(
        &mut self,
        requester: &Keypair,
        wallet: &Pubkey,
        request: Pubkey,
    ) -> Result<(), String> {
        let ix = build(
            acc::Withdraw {
                config: self.config,
                introer: introer_key(wallet),
                request,
                requester: requester.pubkey(),
            },
            ix::Withdraw {},
        );
        self.run(requester, ix)
    }

    fn decline(
        &mut self,
        wallet: &Keypair,
        request: Pubkey,
        requester: Pubkey,
    ) -> Result<(), String> {
        let ix = build(
            acc::Decline {
                config: self.config,
                introer: introer_key(&wallet.pubkey()),
                request,
                wallet: wallet.pubkey(),
                requester,
            },
            ix::Decline {},
        );
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
                config: self.config,
                introer,
                request,
                wallet,
                requester,
            },
            ix::Confirm {},
        )
    }

    /// The request's own introer PDA (or the wallet's, once it is closed).
    fn owner_of(&self, request: Pubkey, wallet: Pubkey) -> Pubkey {
        self.svm
            .get_account(&request)
            .filter(|a| a.lamports > 0)
            .map_or(introer_key(&wallet), |_| self.request(&request).introer)
    }

    fn confirm(
        &mut self,
        requester: &Keypair,
        wallet: Pubkey,
        request: Pubkey,
    ) -> Result<(), String> {
        let introer = self.owner_of(request, wallet);
        let ix = self.confirm_ix(introer, wallet, request, requester.pubkey());
        self.run(requester, ix)
    }

    fn dispute(&mut self, signer: &Keypair, request: Pubkey) -> Result<(), String> {
        let ix = build(
            acc::Dispute {
                request,
                requester: signer.pubkey(),
            },
            ix::Dispute {},
        );
        self.run(signer, ix)
    }

    fn release(
        &mut self,
        caller: &Keypair,
        introer: Pubkey,
        wallet: Pubkey,
        request: Pubkey,
        requester: Pubkey,
    ) -> Result<(), String> {
        let ix = build(
            acc::Release {
                config: self.config,
                introer,
                request,
                wallet,
                requester,
            },
            ix::ReleaseExpired {},
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
        let ix = build(
            acc::RefundExpired {
                config: self.config,
                introer: introer_key(&wallet),
                request,
                requester,
            },
            ix::RefundExpired {},
        );
        self.run(caller, ix)
    }

    fn resolve(
        &mut self,
        arbiter: &Keypair,
        wallet: Pubkey,
        request: Pubkey,
        requester: Pubkey,
        to_introer: bool,
    ) -> Result<(), String> {
        let ix = build(
            acc::Resolve {
                config: self.config,
                arbiter: arbiter.pubkey(),
                introer: self.owner_of(request, wallet),
                request,
                wallet,
                requester,
            },
            ix::Resolve { to_introer },
        );
        self.run(arbiter, ix)
    }

    fn admin_ix(&self, admin: Pubkey, data: impl InstructionData) -> Instruction {
        build(
            acc::AdminOnly {
                config: self.config,
                admin,
            },
            data,
        )
    }

    fn set_paused(&mut self, paused: bool) {
        let ix = self.admin_ix(self.admin.pubkey(), ix::SetPaused { paused });
        let admin = self.admin.insecure_clone();
        self.run(&admin, ix).unwrap();
    }

    /// Accepted and made request, ready to confirm or dispute.
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
    assert_eq!(config.arbiter, t.arbiter.pubkey());
    assert_eq!(config.cap_total, CAP);
    assert_eq!(config.total_held, 0);
    assert!(!config.paused);
}

#[test]
fn init_config_rejects_non_upgrade_authority() {
    let authority = Keypair::new();
    let mut svm = chain(Some(authority.pubkey()));
    let other = funded(&mut svm, 5);
    fails(
        send(
            &mut svm,
            &other,
            init_config_ix(other.pubkey(), other.pubkey(), CAP),
        ),
        "NotUpgradeAuthority",
    );
    assert!(svm.get_account(&config_key()).is_none());
}

#[test]
fn init_config_rejects_everyone_when_program_is_immutable() {
    let mut svm = chain(None);
    let other = funded(&mut svm, 5);
    fails(
        send(
            &mut svm,
            &other,
            init_config_ix(other.pubkey(), other.pubkey(), CAP),
        ),
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
    let mut ix = init_config_ix(attacker.pubkey(), attacker.pubkey(), CAP);
    ix.accounts[3].pubkey = fake;
    fails(send(&mut svm, &attacker, ix), "NotUpgradeAuthority");
}

#[test]
fn init_config_runs_only_once() {
    let mut t = T::new();
    let admin = t.admin.insecure_clone();
    let ix = init_config_ix(admin.pubkey(), admin.pubkey(), 1);
    assert!(send(&mut t.svm, &admin, ix).is_err());
    assert_eq!(t.config().cap_total, CAP);
}

#[test]
fn admin_setters_work_and_reject_others() {
    let mut t = T::new();
    let admin = t.admin.insecure_clone();
    let stranger = t.user(1);
    let new_admin = t.user(1);
    let squads = Pubkey::new_unique();

    for ix in [
        t.admin_ix(stranger.pubkey(), ix::SetPaused { paused: true }),
        t.admin_ix(stranger.pubkey(), ix::SetCap { cap_total: 1 }),
        t.admin_ix(stranger.pubkey(), ix::SetArbiter { arbiter: squads }),
        t.admin_ix(stranger.pubkey(), ix::SetAdmin { admin: squads }),
    ] {
        fails(t.run(&stranger, ix), "Unauthorized");
    }

    for ix in [
        t.admin_ix(admin.pubkey(), ix::SetArbiter { arbiter: squads }),
        t.admin_ix(admin.pubkey(), ix::SetCap { cap_total: 7 }),
        t.admin_ix(admin.pubkey(), ix::SetPaused { paused: true }),
        t.admin_ix(
            admin.pubkey(),
            ix::SetAdmin {
                admin: new_admin.pubkey(),
            },
        ),
    ] {
        t.run(&admin, ix).unwrap();
    }
    let config = t.config();
    assert_eq!(config.arbiter, squads);
    assert_eq!(config.cap_total, 7);
    assert!(config.paused);
    assert_eq!(config.admin, new_admin.pubkey());

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

// ---------- introer ----------

#[test]
fn register_introer_stores_terms() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR * 3);
    let introer = t.introer(&wallet.pubkey());
    assert_eq!(introer.wallet, wallet.pubkey());
    assert_eq!(&introer.badge_id, b"BP26-001");
    assert_eq!(introer.min_bid, MIN_BID_FLOOR * 3);
    assert_eq!(introer.next_id, 0);
    assert_eq!(introer.open_count, 0);
    assert_eq!(introer.jobs_done, 0);
    assert_eq!(introer.created_at, t.now());
    // Registering twice fails.
    assert!(t.register(&wallet, MIN_BID_FLOOR).is_err());
}

#[test]
fn register_introer_checks_min_bid_and_offer() {
    let mut t = T::new();
    let wallet = t.user(1);
    fails(t.register(&wallet, MIN_BID_FLOOR - 1), "BidTooLow");
    fails(t.register(&wallet, MAX_BID + 1), "BidTooHigh");
    let ix = build(
        acc::RegisterIntroer {
            introer: introer_key(&wallet.pubkey()),
            wallet: wallet.pubkey(),
            system_program: anchor_lang::system_program::ID,
        },
        ix::RegisterIntroer {
            badge_id: [0; 8],
            offer: "x".repeat(65),
            min_bid: MIN_BID_FLOOR,
        },
    );
    fails(t.run(&wallet, ix), "TextTooLong");
}

#[test]
fn update_introer_only_by_owner() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let stranger = t.user(1);
    let update = |signer: Pubkey, min_bid: u64| {
        build(
            acc::UpdateIntroer {
                introer: introer_key(&wallet.pubkey()),
                wallet: signer,
            },
            ix::UpdateIntroer {
                offer: "New offer".into(),
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
    assert_eq!(introer.offer, "New offer");
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
    assert_eq!(stored.target, "Toly");
    assert_eq!(stored.telegram, "@alice");
    assert_eq!(stored.created_at, t.now());
    assert_eq!(t.introer(&wallet.pubkey()).open_count, 1);
    assert_eq!(t.introer(&wallet.pubkey()).next_id, 1);
    assert_eq!(t.config().total_held, bid);

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
    assert_eq!(t.config().total_held, 0);

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
    fails_bid(t.try_bid(&requester, &w, SOL - 1, None, &[]), "BidTooLow");
    fails_bid(
        t.try_bid(&requester, &w, MAX_BID + 1, None, &[]),
        "BidTooHigh",
    );
    t.try_bid(&requester, &w, MAX_BID, None, &[]).unwrap();

    let text_bid = |t: &T, target: String, telegram: String| {
        let mut ix = t.bid_ix(&requester.pubkey(), &w, SOL, None, &[]);
        ix.data = ix::Bid {
            target,
            telegram,
            amount: SOL,
        }
        .data();
        ix
    };
    let ix = text_bid(&t, "x".repeat(65), "@a".into());
    fails(t.run(&requester, ix), "TextTooLong");
    let ix = text_bid(&t, String::new(), "@a".into());
    fails(t.run(&requester, ix), "TextTooLong");
    let ix = text_bid(&t, "x".repeat(64), "@".repeat(33));
    fails(t.run(&requester, ix), "TextTooLong");
    let ix = text_bid(&t, "x".repeat(64), "@".repeat(32));
    t.live.push(request_key(&introer_key(&w), 1));
    t.run(&requester, ix).unwrap();
}

#[test]
fn bid_respects_cap_total() {
    let mut t = T::with_cap(3 * SOL);
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(20);
    let w = wallet.pubkey();
    t.bid(&requester, &w, 2 * SOL);
    fails_bid(t.try_bid(&requester, &w, SOL + 1, None, &[]), "OverCap");
    t.bid(&requester, &w, SOL);
    assert_eq!(t.config().total_held, 3 * SOL);
    fails_bid(
        t.try_bid(&requester, &w, MIN_BID_FLOOR, None, &[]),
        "OverCap",
    );
}

#[test]
fn bid_to_unknown_introer_fails() {
    let mut t = T::new();
    let requester = t.user(5);
    let nobody = Pubkey::new_unique();
    let ix = t.bid_ix(&requester.pubkey(), &nobody, SOL, None, &[]);
    assert!(t.run(&requester, ix).is_err());
}

#[test]
fn bid_with_wrong_request_id_fails() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(5);
    let mut ix = t.bid_ix(&requester.pubkey(), &wallet.pubkey(), SOL, None, &[]);
    ix.accounts[2].pubkey = request_key(&introer_key(&wallet.pubkey()), 7);
    assert!(t.run(&requester, ix).is_err());
}

#[test]
fn paused_blocks_bids_but_not_payouts_or_refunds() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(20);
    let w = wallet.pubkey();
    let to_confirm = t.bid(&requester, &w, SOL);
    let to_withdraw = t.bid(&requester, &w, SOL);
    let to_decline = t.bid(&requester, &w, SOL);
    let to_release = t.bid(&requester, &w, SOL);
    let to_refund = t.bid(&requester, &w, SOL);
    for r in [to_confirm, to_release, to_refund] {
        t.accept(&wallet, r).unwrap();
    }
    t.made(&wallet, to_release).unwrap();
    t.set_paused(true);

    fails_bid(t.try_bid(&requester, &w, SOL, None, &[]), "Paused");
    t.confirm(&requester, w, to_confirm).unwrap();
    t.withdraw(&requester, &w, to_withdraw).unwrap();
    t.decline(&wallet, to_decline, requester.pubkey()).unwrap();
    t.warp(WORK_WINDOW + 1);
    let anyone = t.user(1);
    t.release(&anyone, introer_key(&w), w, to_release, requester.pubkey())
        .unwrap();
    t.refund_expired(&anyone, w, to_refund, requester.pubkey())
        .unwrap();
    assert_eq!(t.config().total_held, 0);
    assert_eq!(t.introer(&w).jobs_done, 2);

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

fn all_but(open: &[(Keypair, Pubkey)], skip: Pubkey) -> Vec<Pubkey> {
    open.iter().map(|o| o.1).filter(|k| *k != skip).collect()
}

#[test]
fn full_queue_needs_the_lowest_request() {
    let mut t = T::new();
    let (wallet, open) = full_queue(&mut t);
    let w = wallet.pubkey();
    let newcomer = t.user(10);
    fails_bid(t.try_bid(&newcomer, &w, 9 * SOL, None, &[]), "QueueFull");
    let others = all_but(&open, open[1].1);
    let lowest = Some((open[1].1, open[1].0.pubkey()));

    // Not beating the lowest bid fails, ties included.
    fails_bid(t.try_bid(&newcomer, &w, SOL, lowest, &others), "BidTooLow");
    // Passing a request that is not the lowest fails.
    let not_lowest = Some((open[0].1, open[0].0.pubkey()));
    let rest = all_but(&open, open[0].1);
    fails_bid(
        t.try_bid(&newcomer, &w, 9 * SOL, not_lowest, &rest),
        "NotLowest",
    );
    // Missing, duplicated or self-including others fail.
    fails_bid(
        t.try_bid(&newcomer, &w, 9 * SOL, lowest, &others[..3]),
        "WrongRequest",
    );
    let dup = [others[0], others[0], others[1], others[2]];
    fails_bid(
        t.try_bid(&newcomer, &w, 9 * SOL, lowest, &dup),
        "WrongRequest",
    );
    let with_lowest = [open[1].1, others[0], others[1], others[2]];
    fails_bid(
        t.try_bid(&newcomer, &w, 9 * SOL, lowest, &with_lowest),
        "WrongRequest",
    );
    // The refund must go to the stored requester.
    let swapped = Some((open[1].1, newcomer.pubkey()));
    fails_bid(
        t.try_bid(&newcomer, &w, 9 * SOL, swapped, &others),
        "WrongRequester",
    );
    // Nothing moved.
    assert_eq!(t.introer(&w).open_count, MAX_OPEN);
    assert_eq!(t.config().total_held, 15 * SOL);
}

#[test]
fn outbid_refunds_and_closes_the_lowest() {
    let mut t = T::new();
    let (wallet, open) = full_queue(&mut t);
    let w = wallet.pubkey();
    let (loser, lowest) = (&open[1].0, open[1].1);
    let loser_before = t.lamports(&loser.pubkey());
    let lowest_lamports = t.lamports(&lowest);
    let others = all_but(&open, lowest);
    let newcomer = t.user(10);
    let request = t
        .try_bid(
            &newcomer,
            &w,
            SOL + 1,
            Some((lowest, loser.pubkey())),
            &others,
        )
        .unwrap();
    assert!(t.gone(&lowest));
    assert_eq!(t.lamports(&loser.pubkey()), loser_before + lowest_lamports);
    assert_eq!(t.request(&request).bid, SOL + 1);
    assert_eq!(t.introer(&w).open_count, MAX_OPEN);
    assert_eq!(t.config().total_held, 14 * SOL + SOL + 1);
    // The refunded request cannot be settled again.
    fails(t.withdraw(loser, &w, lowest), "AccountNotInitialized");
}

#[test]
fn outbid_cannot_take_accepted_or_foreign_requests() {
    let mut t = T::new();
    let (wallet, open) = full_queue(&mut t);
    let w = wallet.pubkey();
    let other_wallet = t.introer_with(MIN_BID_FLOOR);
    let other_requester = t.user(5);
    let foreign = t.bid(&other_requester, &other_wallet.pubkey(), MIN_BID_FLOOR);
    let newcomer = t.user(10);
    // Another introer's request as the lowest.
    let others = all_but(&open, open[1].1);
    fails_bid(
        t.try_bid(
            &newcomer,
            &w,
            9 * SOL,
            Some((foreign, other_requester.pubkey())),
            &others,
        ),
        "WrongRequest",
    );
    // Another introer's request smuggled in as an "other".
    let lowest = Some((open[1].1, open[1].0.pubkey()));
    let smuggled = [open[0].1, open[2].1, open[3].1, foreign];
    fails_bid(
        t.try_bid(&newcomer, &w, 9 * SOL, lowest, &smuggled),
        "WrongRequest",
    );
    // Accept the lowest, then fill the slot again: the accepted request can
    // no longer be passed as the lowest, nor as an "other".
    t.accept(&wallet, open[1].1).unwrap();
    let filler = t.try_bid(&newcomer, &w, 2 * SOL, None, &[]).unwrap();
    let mut queue = all_but(&open, open[1].1);
    queue.push(filler);
    fails_bid(
        t.try_bid(&newcomer, &w, 9 * SOL, lowest, &queue[1..]),
        "BadStatus",
    );
    let first = Some((open[0].1, open[0].0.pubkey()));
    let with_accepted = [open[1].1, open[2].1, open[3].1, open[4].1];
    fails_bid(
        t.try_bid(&newcomer, &w, 9 * SOL, first, &with_accepted),
        "WrongRequest",
    );
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
        &[],
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

// ---------- confirm / dispute / release ----------

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
    ix.accounts[4].is_signer = false;
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

    t.warp(CONFIRM_WINDOW + 1);
    let anyone = t.user(1);
    let i = introer_key(&w);
    fails(
        t.release(&anyone, i, thief.pubkey(), request, r),
        "WrongWallet",
    );
    fails(
        t.release(&anyone, i, w, request, thief.pubkey()),
        "WrongRequester",
    );
    let thief_introer = introer_key(&thief.pubkey());
    assert!(t
        .release(&anyone, thief_introer, thief.pubkey(), request, r)
        .is_err());
    assert_eq!(t.introer(&thief.pubkey()).jobs_done, 0);
    let before = t.lamports(&w);
    t.release(&anyone, i, w, request, r).unwrap();
    assert_eq!(t.lamports(&w), before + SOL);
}

#[test]
fn dispute_only_by_requester_within_window() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(SOL);
    let w = wallet.pubkey();
    let stranger = t.user(1);
    fails(t.dispute(&stranger, request), "WrongRequester");
    t.warp(CONFIRM_WINDOW);
    t.dispute(&requester, request).unwrap();
    assert_eq!(t.request(&request).status, STATUS_DISPUTED);
    fails(t.dispute(&requester, request), "BadStatus");
    // Disputed jobs can't be confirmed, released or refunded.
    fails(t.confirm(&requester, w, request), "BadStatus");
    t.warp(WORK_WINDOW);
    let anyone = t.user(1);
    fails(
        t.release(&anyone, introer_key(&w), w, request, requester.pubkey()),
        "BadStatus",
    );
    fails(
        t.refund_expired(&anyone, w, request, requester.pubkey()),
        "BadStatus",
    );

    let (_, requester, request) = t.made_request(SOL);
    t.warp(CONFIRM_WINDOW + 1);
    fails(t.dispute(&requester, request), "WindowClosed");

    // Not disputable before it is made.
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let request = t.bid(&requester, &wallet.pubkey(), SOL);
    fails(t.dispute(&requester, request), "BadStatus");
    t.accept(&wallet, request).unwrap();
    fails(t.dispute(&requester, request), "BadStatus");
}

#[test]
fn release_expired_waits_for_the_confirm_window() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(SOL);
    let (w, r) = (wallet.pubkey(), requester.pubkey());
    let anyone = t.user(1);
    let introer = introer_key(&w);
    t.warp(CONFIRM_WINDOW);
    fails(t.release(&anyone, introer, w, request, r), "NotExpired");
    t.warp(1);
    let rent = t.lamports(&request) - SOL;
    let requester_before = t.lamports(&r);
    let wallet_before = t.lamports(&w);
    t.release(&anyone, introer, w, request, r).unwrap();
    assert!(t.gone(&request));
    assert_eq!(t.lamports(&w), wallet_before + SOL);
    assert_eq!(t.lamports(&r), requester_before + rent);
    assert_eq!(t.introer(&w).jobs_done, 1);
    // Double settle is impossible.
    assert!(t.release(&anyone, introer, w, request, r).is_err());
    assert!(t.confirm(&requester, w, request).is_err());
    assert_eq!(t.introer(&w).jobs_done, 1);
}

#[test]
fn release_expired_needs_made() {
    let mut t = T::new();
    let wallet = t.introer_with(MIN_BID_FLOOR);
    let w = wallet.pubkey();
    let requester = t.user(10);
    let request = t.bid(&requester, &w, SOL);
    t.accept(&wallet, request).unwrap();
    t.warp(WORK_WINDOW * 2);
    let anyone = t.user(1);
    fails(
        t.release(&anyone, introer_key(&w), w, request, requester.pubkey()),
        "BadStatus",
    );
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
    fails(t.refund_expired(&anyone, w, request, r), "BadStatus");
    t.accept(&wallet, request).unwrap();
    t.warp(WORK_WINDOW);
    fails(t.refund_expired(&anyone, w, request, r), "NotExpired");
    t.warp(1);
    fails(
        t.refund_expired(&anyone, w, request, anyone.pubkey()),
        "WrongRequester",
    );
    let before = t.lamports(&r);
    let held = t.lamports(&request);
    t.refund_expired(&anyone, w, request, r).unwrap();
    assert_eq!(t.lamports(&r), before + held);
    assert_eq!(t.introer(&w).jobs_done, 0);
    assert!(t.refund_expired(&anyone, w, request, r).is_err());
}

#[test]
fn refund_expired_does_not_apply_once_made() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(SOL);
    t.warp(WORK_WINDOW * 2);
    let anyone = t.user(1);
    fails(
        t.refund_expired(&anyone, wallet.pubkey(), request, requester.pubkey()),
        "BadStatus",
    );
}

// ---------- arbiter ----------

#[test]
fn arbiter_resolves_to_introer() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(3 * SOL);
    let (w, r) = (wallet.pubkey(), requester.pubkey());
    t.dispute(&requester, request).unwrap();
    let arbiter = t.arbiter.insecure_clone();
    let wallet_before = t.lamports(&w);
    let rent = t.lamports(&request) - 3 * SOL;
    let requester_before = t.lamports(&r);
    t.resolve(&arbiter, w, request, r, true).unwrap();
    assert_eq!(t.lamports(&w), wallet_before + 3 * SOL);
    assert_eq!(t.lamports(&r), requester_before + rent);
    let introer = t.introer(&w);
    assert_eq!((introer.jobs_done, introer.earned), (1, 3 * SOL));
    assert!(t.resolve(&arbiter, w, request, r, false).is_err());
}

#[test]
fn arbiter_resolves_to_requester() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(3 * SOL);
    let (w, r) = (wallet.pubkey(), requester.pubkey());
    t.dispute(&requester, request).unwrap();
    let arbiter = t.arbiter.insecure_clone();
    let held = t.lamports(&request);
    let before = t.lamports(&r);
    let wallet_before = t.lamports(&w);
    t.resolve(&arbiter, w, request, r, false).unwrap();
    assert_eq!(t.lamports(&r), before + held);
    assert_eq!(t.lamports(&w), wallet_before);
    assert_eq!(t.introer(&w).jobs_done, 0);
}

#[test]
fn resolve_needs_arbiter_and_dispute() {
    let mut t = T::new();
    let (wallet, requester, request) = t.made_request(SOL);
    let (w, r) = (wallet.pubkey(), requester.pubkey());
    let arbiter = t.arbiter.insecure_clone();
    fails(t.resolve(&arbiter, w, request, r, true), "BadStatus");
    t.dispute(&requester, request).unwrap();
    let admin = t.admin.insecure_clone();
    fails(t.resolve(&admin, w, request, r, true), "Unauthorized");
    fails(t.resolve(&requester, w, request, r, false), "Unauthorized");
    let thief = t.user(1);
    fails(
        t.resolve(&arbiter, thief.pubkey(), request, r, true),
        "WrongWallet",
    );
    fails(
        t.resolve(&arbiter, w, request, thief.pubkey(), false),
        "WrongRequester",
    );
    // A new arbiter takes over.
    let next = t.user(1);
    let ix = t.admin_ix(
        admin.pubkey(),
        ix::SetArbiter {
            arbiter: next.pubkey(),
        },
    );
    t.run(&admin, ix).unwrap();
    fails(t.resolve(&arbiter, w, request, r, true), "Unauthorized");
    t.resolve(&next, w, request, r, true).unwrap();
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
    assert_eq!(t.config().total_held, 0);
}

#[test]
fn many_requests_keep_books_balanced() {
    let mut t = T::new();
    let a = t.introer_with(MIN_BID_FLOOR);
    let b = t.introer_with(MIN_BID_FLOOR);
    let requester = t.user(200);
    let r1 = t.bid(&requester, &a.pubkey(), SOL);
    let r2 = t.bid(&requester, &b.pubkey(), 2 * SOL);
    let r3 = t.bid(&requester, &a.pubkey(), 3 * SOL);
    let r4 = t.bid(&requester, &b.pubkey(), 4 * SOL);
    assert_eq!(t.config().total_held, 10 * SOL);
    // Requests of one introer can't be driven through the other.
    assert!(t.accept(&b, r1).is_err());
    assert!(t.decline(&a, r2, requester.pubkey()).is_err());
    t.accept(&a, r1).unwrap();
    t.confirm(&requester, a.pubkey(), r1).unwrap();
    t.decline(&b, r2, requester.pubkey()).unwrap();
    t.withdraw(&requester, &a.pubkey(), r3).unwrap();
    t.accept(&b, r4).unwrap();
    t.made(&b, r4).unwrap();
    t.dispute(&requester, r4).unwrap();
    let arbiter = t.arbiter.insecure_clone();
    t.resolve(&arbiter, b.pubkey(), r4, requester.pubkey(), true)
        .unwrap();
    assert_eq!(t.config().total_held, 0);
    assert_eq!(t.introer(&a.pubkey()).earned, SOL);
    assert_eq!(t.introer(&b.pubkey()).earned, 4 * SOL);
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
