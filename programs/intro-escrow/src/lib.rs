//! Intro Bot escrow: public intro requests with SOL bids held until the intro
//! is confirmed. See `docs/spec.md` ("Program: intro_escrow").
#![allow(unexpected_cfgs, reason = "anchor macros emit cfgs")]

use anchor_lang::prelude::*;
use anchor_lang::system_program;
pub use solana_native_token::LAMPORTS_PER_SOL;

declare_id!("GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC");

pub const MAX_BID: u64 = 100 * LAMPORTS_PER_SOL;
pub const MIN_BID_FLOOR: u64 = LAMPORTS_PER_SOL / 100;
pub const MAX_OPEN: u8 = 5;
pub const CONFIRM_WINDOW: i64 = 72 * 60 * 60;
pub const WORK_WINDOW: i64 = 7 * 24 * 60 * 60;
/// An open bid can be withdrawn only this long after it was placed.
pub const WITHDRAW_DELAY: i64 = 24 * 60 * 60;
/// An outbid must beat the lowest open bid by at least this percent.
pub const OUTBID_PERCENT: u64 = 10;
pub const MAX_TARGET: usize = 64;
pub const MAX_TELEGRAM: usize = 32;
pub const MAX_OFFER: usize = 64;

pub const STATUS_OPEN: u8 = 0;
pub const STATUS_ACCEPTED: u8 = 1;
pub const STATUS_MADE: u8 = 2;

/// `Refunded.reason` values.
pub const REFUND_WITHDRAWN: u8 = 0;
pub const REFUND_DECLINED: u8 = 1;
pub const REFUND_OUTBID: u8 = 2;
pub const REFUND_EXPIRED: u8 = 3;
pub const REFUND_UNCONFIRMED: u8 = 4;
/// Wallets kept in the directory ring.
pub const DIRECTORY_LEN: usize = 32;

#[program]
pub mod intro_escrow {
    use super::*;

    /// Creates the config and directory. Only the program's upgrade
    /// authority can call it; the signer becomes the admin.
    pub fn init_config(ctx: Context<InitConfig>) -> Result<()> {
        ctx.accounts.config.set_inner(Config {
            admin: ctx.accounts.authority.key(),
            pending_admin: Pubkey::default(),
            paused: false,
            bump: ctx.bumps.config,
        });
        ctx.accounts.directory.set_inner(Directory {
            head: 0,
            bump: ctx.bumps.directory,
            wallets: [Pubkey::default(); DIRECTORY_LEN],
        });
        Ok(())
    }

    /// Step 1 of an admin change: names the next admin, who must accept.
    pub fn propose_admin(ctx: Context<AdminOnly>, admin: Pubkey) -> Result<()> {
        require_keys_neq!(admin, Pubkey::default(), EscrowError::NoAdmin);
        ctx.accounts.config.pending_admin = admin;
        emit!(AdminProposed { admin });
        Ok(())
    }

    /// Admin withdraws a pending proposal.
    pub fn cancel_admin_proposal(ctx: Context<AdminOnly>) -> Result<()> {
        let config = &mut ctx.accounts.config;
        let admin = config.pending_admin;
        config.pending_admin = Pubkey::default();
        emit!(AdminProposalCancelled { admin });
        Ok(())
    }

    /// Step 2: the proposed admin signs to take over.
    pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
        let config = &mut ctx.accounts.config;
        config.admin = config.pending_admin;
        config.pending_admin = Pubkey::default();
        emit!(AdminAccepted {
            admin: config.admin
        });
        Ok(())
    }

    pub fn set_paused(ctx: Context<AdminOnly>, paused: bool) -> Result<()> {
        ctx.accounts.config.paused = paused;
        Ok(())
    }

    pub fn register_introer(
        ctx: Context<RegisterIntroer>,
        badge_id: [u8; 8],
        offer: [u8; MAX_OFFER],
        min_bid: u64,
    ) -> Result<()> {
        check_terms(&offer, min_bid)?;
        let wallet = ctx.accounts.wallet.key();
        let introer = &mut ctx.accounts.introer;
        introer.set_inner(Introer {
            wallet,
            min_bid,
            next_id: 0,
            jobs_done: 0,
            earned: 0,
            created_at: Clock::get()?.unix_timestamp,
            open_count: 0,
            bump: ctx.bumps.introer,
            badge_id,
            offer,
            open: [OpenSlot::default(); MAX_OPEN as usize],
        });
        ctx.accounts.directory.add(wallet);
        emit!(IntroerRegistered {
            introer: introer.key(),
            wallet,
            badge_id,
            min_bid,
        });
        Ok(())
    }

    pub fn update_introer(
        ctx: Context<UpdateIntroer>,
        offer: [u8; MAX_OFFER],
        min_bid: u64,
    ) -> Result<()> {
        check_terms(&offer, min_bid)?;
        let introer = &mut ctx.accounts.introer;
        introer.offer = offer;
        introer.min_bid = min_bid;
        Ok(())
    }

    /// Posts a request with `amount` lamports held in the request account.
    /// With `MAX_OPEN` open requests, `lowest` must be the lowest of them
    /// (as tracked in `introer.open`); it is refunded and closed.
    pub fn bid(
        ctx: Context<Bid>,
        target: [u8; MAX_TARGET],
        telegram: [u8; MAX_TELEGRAM],
        amount: u64,
    ) -> Result<()> {
        let a = ctx.accounts;
        require!(!a.config.paused, EscrowError::Paused);
        require_keys_neq!(a.requester.key(), a.introer.wallet, EscrowError::SelfBid);
        require!(target[0] != 0 && telegram[0] != 0, EscrowError::BadText);
        check_text(&target)?;
        check_text(&telegram)?;
        require!(amount <= MAX_BID, EscrowError::BidTooHigh);
        require!(amount >= a.introer.min_bid, EscrowError::BidTooLow);

        // Move the bid in before any eviction: a CPI after closing an
        // account the requester also appears as fails the balance check.
        system_program::transfer(
            CpiContext::new(
                a.system_program.key(),
                system_program::Transfer {
                    from: a.requester.to_account_info(),
                    to: a.request.to_account_info(),
                },
            ),
            amount,
        )?;

        if a.introer.open_count >= MAX_OPEN {
            evict_lowest(
                &mut a.introer,
                a.lowest.as_ref(),
                a.lowest_requester.as_ref(),
                amount,
            )?;
        }

        let introer = &mut a.introer;
        let id = introer.next_id;
        introer.next_id = id.checked_add(1).ok_or(EscrowError::Overflow)?;
        introer.push_open(id, amount)?;
        a.request.set_inner(Request {
            introer: introer.key(),
            requester: a.requester.key(),
            id,
            bid: amount,
            status: STATUS_OPEN,
            created_at: Clock::get()?.unix_timestamp,
            accepted_at: 0,
            made_at: 0,
            bump: ctx.bumps.request,
            target,
            telegram,
        });
        emit!(BidPlaced {
            request: a.request.key(),
            introer: introer.key(),
            requester: a.requester.key(),
            bid: amount,
        });
        Ok(())
    }

    /// Requester takes back an open request, once `WITHDRAW_DELAY` passed.
    pub fn withdraw(ctx: Context<Withdraw>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_OPEN, EscrowError::BadStatus);
        let ready = a
            .request
            .created_at
            .checked_add(WITHDRAW_DELAY)
            .ok_or(EscrowError::Overflow)?;
        require!(Clock::get()?.unix_timestamp >= ready, EscrowError::TooEarly);
        a.introer.remove_open(a.request.id)?;
        emit!(Withdrawn {
            request: a.request.key()
        });
        emit_refund(&a.request, REFUND_WITHDRAWN);
        Ok(())
    }

    pub fn accept(ctx: Context<IntroerStep>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_OPEN, EscrowError::BadStatus);
        a.introer.remove_open(a.request.id)?;
        a.request.status = STATUS_ACCEPTED;
        a.request.accepted_at = Clock::get()?.unix_timestamp;
        emit!(Accepted {
            request: a.request.key()
        });
        Ok(())
    }

    /// Introer turns down an open request; it is refunded.
    pub fn decline(ctx: Context<Decline>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_OPEN, EscrowError::BadStatus);
        a.introer.remove_open(a.request.id)?;
        emit!(Declined {
            request: a.request.key()
        });
        emit_refund(&a.request, REFUND_DECLINED);
        Ok(())
    }

    /// Introer marks the intro made, within `WORK_WINDOW` of accepting.
    pub fn mark_made(ctx: Context<IntroerStep>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_ACCEPTED, EscrowError::BadStatus);
        let now = Clock::get()?.unix_timestamp;
        let deadline = a
            .request
            .accepted_at
            .checked_add(WORK_WINDOW)
            .ok_or(EscrowError::Overflow)?;
        require!(now <= deadline, EscrowError::WorkExpired);
        a.request.status = STATUS_MADE;
        a.request.made_at = now;
        emit!(Made {
            request: a.request.key(),
            made_at: now,
        });
        Ok(())
    }

    /// Requester confirms the intro; the introer is paid.
    pub fn confirm(ctx: Context<Confirm>) -> Result<()> {
        let a = ctx.accounts;
        require!(
            a.request.status == STATUS_MADE || a.request.status == STATUS_ACCEPTED,
            EscrowError::BadStatus
        );
        let bid = a.request.bid;
        a.request.sub_lamports(bid)?;
        a.wallet.add_lamports(bid)?;
        let introer = &mut a.introer;
        introer.jobs_done = introer
            .jobs_done
            .checked_add(1)
            .ok_or(EscrowError::Overflow)?;
        introer.earned = introer
            .earned
            .checked_add(bid)
            .ok_or(EscrowError::Overflow)?;
        emit!(Receipt {
            request: a.request.key(),
            introer: introer.key(),
            requester: a.requester.key(),
            bid,
            jobs_done: introer.jobs_done,
            earned: introer.earned,
        });
        Ok(())
    }

    /// Anyone: refunds a made request the requester never confirmed. The
    /// introer is paid only by `confirm`.
    pub fn refund_unconfirmed(ctx: Context<RefundExpired>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_MADE, EscrowError::BadStatus);
        let deadline = a
            .request
            .made_at
            .checked_add(CONFIRM_WINDOW)
            .ok_or(EscrowError::Overflow)?;
        require!(
            Clock::get()?.unix_timestamp > deadline,
            EscrowError::NotExpired
        );
        emit_refund(&a.request, REFUND_UNCONFIRMED);
        Ok(())
    }

    /// Refunds an accepted request the introer never marked made. The
    /// requester can call it after `WORK_WINDOW`; anyone else must wait
    /// `CONFIRM_WINDOW` more, so a late confirm can't be sniped.
    pub fn refund_expired(ctx: Context<RefundExpired>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_ACCEPTED, EscrowError::BadStatus);
        let wait = if a.caller.key() == a.request.requester {
            WORK_WINDOW
        } else {
            WORK_WINDOW + CONFIRM_WINDOW
        };
        let deadline = a
            .request
            .accepted_at
            .checked_add(wait)
            .ok_or(EscrowError::Overflow)?;
        require!(
            Clock::get()?.unix_timestamp > deadline,
            EscrowError::NotExpired
        );
        emit_refund(&a.request, REFUND_EXPIRED);
        Ok(())
    }
}

/// Text is UTF-8, zero-padded: nothing but zeros after the first zero.
fn check_text(text: &[u8]) -> Result<()> {
    let len = text.iter().position(|b| *b == 0).unwrap_or(text.len());
    let (body, pad) = text.split_at(len);
    require!(pad.iter().all(|b| *b == 0), EscrowError::BadText);
    require!(core::str::from_utf8(body).is_ok(), EscrowError::BadText);
    Ok(())
}

fn check_terms(offer: &[u8], min_bid: u64) -> Result<()> {
    check_text(offer)?;
    require!(min_bid >= MIN_BID_FLOOR, EscrowError::BidTooLow);
    require!(min_bid <= MAX_BID, EscrowError::BidTooHigh);
    Ok(())
}

fn emit_refund(request: &Account<Request>, reason: u8) {
    emit!(Refunded {
        request: request.key(),
        reason,
    });
}

/// Refunds and closes the lowest open request so a higher bid can take its
/// slot. The program picks the lowest from `introer.open`.
fn evict_lowest<'info>(
    introer: &mut Account<'info, Introer>,
    lowest: Option<&Account<'info, Request>>,
    lowest_requester: Option<&UncheckedAccount<'info>>,
    amount: u64,
) -> Result<()> {
    let (Some(lowest), Some(lowest_requester)) = (lowest, lowest_requester) else {
        return err!(EscrowError::QueueFull);
    };
    let slot = introer.lowest_open().ok_or(EscrowError::QueueFull)?;
    require_keys_eq!(lowest.introer, introer.key(), EscrowError::WrongRequest);
    require!(lowest.id == slot.id, EscrowError::NotLowest);
    // Implied by being listed in `introer.open`; kept as defense in depth.
    require!(lowest.status == STATUS_OPEN, EscrowError::BadStatus);
    require_keys_eq!(
        lowest_requester.key(),
        lowest.requester,
        EscrowError::WrongRequester
    );
    // Must beat the lowest by OUTBID_PERCENT (rounded up), capped at
    // MAX_BID so a queue near the max can still be outbid.
    let required = (u128::from(lowest.bid) * u128::from(100 + OUTBID_PERCENT)).div_ceil(100);
    let required = u64::try_from(required).unwrap_or(MAX_BID).min(MAX_BID);
    require!(
        amount >= required && amount > lowest.bid,
        EscrowError::BidTooLow
    );

    introer.remove_open(lowest.id)?;
    lowest.close(lowest_requester.to_account_info())?;
    emit!(Outbid {
        request: lowest.key(),
        requester: lowest.requester,
        bid: lowest.bid,
        new_bid: amount,
    });
    emit_refund(lowest, REFUND_OUTBID);
    Ok(())
}

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub admin: Pubkey,
    /// Proposed next admin until it accepts; default when none.
    pub pending_admin: Pubkey,
    pub paused: bool,
    pub bump: u8,
}

/// One open (not yet accepted) request of an introer.
#[derive(
    AnchorSerialize, AnchorDeserialize, Clone, Copy, Default, InitSpace, PartialEq, Eq, Debug,
)]
pub struct OpenSlot {
    pub id: u64,
    pub bid: u64,
}

#[account]
#[derive(InitSpace)]
pub struct Introer {
    pub wallet: Pubkey,
    pub min_bid: u64,
    pub next_id: u64,
    pub jobs_done: u32,
    pub earned: u64,
    pub created_at: i64,
    /// Number of used entries at the front of `open`.
    pub open_count: u8,
    pub bump: u8,
    pub badge_id: [u8; 8],
    /// UTF-8, zero-padded.
    pub offer: [u8; MAX_OFFER],
    /// Open requests; entries past `open_count` are zero.
    pub open: [OpenSlot; MAX_OPEN as usize],
}

impl Introer {
    fn push_open(&mut self, id: u64, bid: u64) -> Result<()> {
        let slot = self
            .open
            .get_mut(usize::from(self.open_count))
            .ok_or(EscrowError::Invariant)?;
        *slot = OpenSlot { id, bid };
        self.open_count = self
            .open_count
            .checked_add(1)
            .ok_or(EscrowError::Overflow)?;
        Ok(())
    }

    /// Removes `id`, moving the last entry into its place.
    fn remove_open(&mut self, id: u64) -> Result<()> {
        let count = usize::from(self.open_count);
        let used = self.open.get(..count).ok_or(EscrowError::Invariant)?;
        let index = used
            .iter()
            .position(|slot| slot.id == id)
            .ok_or(EscrowError::Invariant)?;
        let last = count.checked_sub(1).ok_or(EscrowError::Invariant)?;
        self.open.swap(index, last);
        if let Some(slot) = self.open.get_mut(last) {
            *slot = OpenSlot::default();
        }
        self.open_count = self
            .open_count
            .checked_sub(1)
            .ok_or(EscrowError::Invariant)?;
        Ok(())
    }

    /// Lowest open bid; the oldest one on a tie.
    pub fn lowest_open(&self) -> Option<OpenSlot> {
        self.open
            .get(..usize::from(self.open_count))?
            .iter()
            .min_by_key(|slot| (slot.bid, slot.id))
            .copied()
    }
}

/// Ring of recently registered introer wallets, for clients that can't
/// list program accounts. Anyone can push old entries out by registering
/// new wallets; clients should not rely on it alone.
#[account]
#[derive(InitSpace)]
pub struct Directory {
    /// Next slot to write.
    pub head: u8,
    pub bump: u8,
    pub wallets: [Pubkey; DIRECTORY_LEN],
}

impl Directory {
    /// Writes `wallet` at `head` and advances it. Each wallet registers
    /// once (the introer PDA can't be re-created), so no duplicates.
    pub fn add(&mut self, wallet: Pubkey) {
        let slot = usize::from(self.head) % DIRECTORY_LEN;
        if let Some(entry) = self.wallets.get_mut(slot) {
            *entry = wallet;
        }
        self.head = ((slot + 1) % DIRECTORY_LEN) as u8;
    }
}

#[account]
#[derive(InitSpace)]
pub struct Request {
    /// Introer PDA.
    pub introer: Pubkey,
    pub requester: Pubkey,
    pub id: u64,
    pub bid: u64,
    pub status: u8,
    pub created_at: i64,
    pub accepted_at: i64,
    pub made_at: i64,
    pub bump: u8,
    /// UTF-8, zero-padded.
    pub target: [u8; MAX_TARGET],
    /// UTF-8, zero-padded.
    pub telegram: [u8; MAX_TELEGRAM],
}

// Account orders are part of the client contract (docs/spec.md): signer first.

#[derive(Accounts)]
pub struct InitConfig<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(init, payer = authority, space = 8 + Config::INIT_SPACE, seeds = [b"config"], bump)]
    pub config: Account<'info, Config>,
    #[account(init, payer = authority, space = 8 + Directory::INIT_SPACE, seeds = [b"directory"], bump)]
    pub directory: Box<Account<'info, Directory>>,
    #[account(constraint = program.programdata_address()? == Some(program_data.key()) @ EscrowError::NotUpgradeAuthority)]
    pub program: Program<'info, program::IntroEscrow>,
    #[account(constraint = program_data.upgrade_authority_address == Some(authority.key()) @ EscrowError::NotUpgradeAuthority)]
    pub program_data: Account<'info, ProgramData>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    pub admin: Signer<'info>,
    #[account(mut, seeds = [b"config"], bump = config.bump, has_one = admin @ EscrowError::Unauthorized)]
    pub config: Account<'info, Config>,
}

#[derive(Accounts)]
pub struct AcceptAdmin<'info> {
    pub pending_admin: Signer<'info>,
    #[account(mut, seeds = [b"config"], bump = config.bump, has_one = pending_admin @ EscrowError::Unauthorized)]
    pub config: Account<'info, Config>,
}

#[derive(Accounts)]
pub struct RegisterIntroer<'info> {
    #[account(mut)]
    pub wallet: Signer<'info>,
    #[account(init, payer = wallet, space = 8 + Introer::INIT_SPACE, seeds = [b"introer", wallet.key().as_ref()], bump)]
    pub introer: Account<'info, Introer>,
    #[account(mut, seeds = [b"directory"], bump = directory.bump)]
    pub directory: Box<Account<'info, Directory>>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateIntroer<'info> {
    pub wallet: Signer<'info>,
    #[account(mut, seeds = [b"introer", wallet.key().as_ref()], bump = introer.bump, has_one = wallet @ EscrowError::Unauthorized)]
    pub introer: Account<'info, Introer>,
}

#[derive(Accounts)]
pub struct Bid<'info> {
    #[account(mut)]
    pub requester: Signer<'info>,
    #[account(seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [b"introer", introer.wallet.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(
        init,
        payer = requester,
        space = 8 + Request::INIT_SPACE,
        seeds = [b"request", introer.key().as_ref(), &introer.next_id.to_le_bytes()],
        bump
    )]
    pub request: Account<'info, Request>,
    pub system_program: Program<'info, System>,
    /// Lowest open request, only needed when the queue is full.
    #[account(mut)]
    pub lowest: Option<Account<'info, Request>>,
    /// CHECK: checked against `lowest.requester` before any refund.
    #[account(mut)]
    pub lowest_requester: Option<UncheckedAccount<'info>>,
}

#[derive(Accounts)]
pub struct Withdraw<'info> {
    #[account(mut)]
    pub requester: Signer<'info>,
    #[account(mut, seeds = [b"introer", introer.wallet.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        close = requester,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
}

#[derive(Accounts)]
pub struct IntroerStep<'info> {
    pub wallet: Signer<'info>,
    #[account(mut, seeds = [b"introer", wallet.key().as_ref()], bump = introer.bump, has_one = wallet @ EscrowError::Unauthorized)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest
    )]
    pub request: Account<'info, Request>,
}

#[derive(Accounts)]
pub struct Decline<'info> {
    pub wallet: Signer<'info>,
    #[account(mut, seeds = [b"introer", wallet.key().as_ref()], bump = introer.bump, has_one = wallet @ EscrowError::Unauthorized)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        close = requester,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
    /// CHECK: must equal `request.requester` (has_one).
    #[account(mut)]
    pub requester: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct Confirm<'info> {
    #[account(mut)]
    pub requester: Signer<'info>,
    #[account(mut, seeds = [b"introer", introer.wallet.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        close = requester,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
    /// CHECK: must equal `introer.wallet`; receives the bid.
    #[account(mut, address = introer.wallet @ EscrowError::WrongWallet)]
    pub wallet: UncheckedAccount<'info>,
}

/// `refund_unconfirmed` and `refund_expired`: anyone can call (see the
/// timing rule in `refund_expired`).
#[derive(Accounts)]
pub struct RefundExpired<'info> {
    pub caller: Signer<'info>,
    #[account(seeds = [b"introer", introer.wallet.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        close = requester,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
    /// CHECK: must equal `request.requester` (has_one); receives bid and rent.
    #[account(mut)]
    pub requester: UncheckedAccount<'info>,
}

#[event]
pub struct AdminProposed {
    pub admin: Pubkey,
}

#[event]
pub struct AdminAccepted {
    pub admin: Pubkey,
}

#[event]
pub struct AdminProposalCancelled {
    /// The proposal that was cleared (default if none).
    pub admin: Pubkey,
}

#[event]
pub struct IntroerRegistered {
    pub introer: Pubkey,
    pub wallet: Pubkey,
    pub badge_id: [u8; 8],
    pub min_bid: u64,
}

#[event]
pub struct BidPlaced {
    pub request: Pubkey,
    pub introer: Pubkey,
    pub requester: Pubkey,
    pub bid: u64,
}

#[event]
pub struct Outbid {
    /// The refunded request.
    pub request: Pubkey,
    pub requester: Pubkey,
    pub bid: u64,
    pub new_bid: u64,
}

#[event]
pub struct Withdrawn {
    pub request: Pubkey,
}

#[event]
pub struct Accepted {
    pub request: Pubkey,
}

#[event]
pub struct Declined {
    pub request: Pubkey,
}

#[event]
pub struct Made {
    pub request: Pubkey,
    pub made_at: i64,
}

#[event]
pub struct Receipt {
    pub request: Pubkey,
    pub introer: Pubkey,
    pub requester: Pubkey,
    pub bid: u64,
    pub jobs_done: u32,
    pub earned: u64,
}

#[event]
pub struct Refunded {
    pub request: Pubkey,
    /// One of the `REFUND_*` constants.
    pub reason: u8,
}

#[error_code]
pub enum EscrowError {
    #[msg("Signer is not the program upgrade authority")]
    NotUpgradeAuthority,
    #[msg("Signer is not allowed")]
    Unauthorized,
    #[msg("Bids are paused")]
    Paused,
    #[msg("Text is empty, not UTF-8 or not zero-padded")]
    BadText,
    #[msg("Bid is above the max")]
    BidTooHigh,
    #[msg("Bid is below the min")]
    BidTooLow,
    #[msg("Introers can't bid on themselves")]
    SelfBid,
    #[msg("Queue is full: pass the lowest open request")]
    QueueFull,
    #[msg("Passed request is not the lowest open one")]
    NotLowest,
    #[msg("Request does not belong to this introer")]
    WrongRequest,
    #[msg("Requester does not match")]
    WrongRequester,
    #[msg("Wallet does not match the introer")]
    WrongWallet,
    #[msg("Request is in the wrong state")]
    BadStatus,
    #[msg("Too early to withdraw")]
    TooEarly,
    #[msg("Work window has passed")]
    WorkExpired,
    #[msg("Not expired yet")]
    NotExpired,
    #[msg("Math overflow")]
    Overflow,
    #[msg("Stored state is inconsistent")]
    Invariant,
    #[msg("Admin can't be the default key")]
    NoAdmin,
}
