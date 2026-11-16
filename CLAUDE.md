# CLAUDE.md

Guidance for Claude Code working in the sphUSD repo.

## What this is

`StakedPhUSD` ("Staked PhUSD", `sphUSD`): an OpenZeppelin ERC4626 vault over phUSD that stakes
into the live PhlimboV3 as one vault-owned position and compounds Phlimbo's rewards (USDC, phUSD
emissions, promo tokens) into the share price via a permissionless, owner-priced `swap`.

## Source repo only

Nothing is deployed from here. There is no `script/` deploy and no `broadcast/`. Deployment
scripts, broadcast artifacts and address registries live in phase-2-staging
(`~/code/reflax-mint/phase-2-staging`). No story ever broadcasts; the human does.

## Layout

Flat Foundry layout: `lib/openzeppelin-contracts` (v5.6.1) and `lib/forge-std` (v1.12.0) as
plain submodules, remappings in `foundry.toml`. External contracts are consumed through vendored,
trimmed interfaces in `src/interfaces/` (PhlimboV3 from `Behodler/phlimbo-ea@f279c62`, the commit
phase-2-staging pins).

```bash
forge build
forge test                                   # fork suite skips without MAINNET_RPC_URL
MAINNET_RPC_URL=<archive rpc> forge test     # includes test/fork/
forge fmt --check
```

## Invariants (do not break)

- `totalAssets() == stakedInPhlimbo + pendingDeposits - pendingWithdrawals`. Accounting is
  explicit; never derive assets from `balanceOf`, so donations and reward drops never move the
  share price.
- `stakedInPhlimbo` is reconciled from `phlimbo.userInfo(vault).amount` after every Phlimbo call
  (absorbs Phlimbo's dust full-withdraw rule).
- Every Phlimbo call is wrapped in phUSD balance-delta measurement; emissions go to
  `pendingDeposits`.
- Queues are always netted (`pendingWithdrawals` against `pendingDeposits`, burning the overlap)
  before touching Phlimbo.
- Withdrawals pay from idle `pendingDeposits` first, then mint the remainder. The vault needs the
  phUSD minter role; a missing role reverts loudly (`StakedPhUSD__MintFailed`), never silently.
- Keeper rewards are paid from owed phUSD being burnt, then minted; never from holder assets.
- `flushAll` is gated at `depositThreshold + withdrawThreshold` and its reward is capped at
  `stakeReward + withdrawFee`; it can never be triggered more cheaply than the individual flushes.
- phUSD and sphUSD can never be swap tokens or swept. Tokens with a non-zero `swapPrice` belong to
  swappers and cannot be swept.
- `pause()` must never revert for the pauser, even when already paused (PauserV2 calls it without
  try/catch). Share transfers are never paused.

## No funds to the owner EOA

The owner EOA `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6` (the human's Ledger) pays gas and
nothing else. No code path may send any token to `owner()`, not even in transit: every payout
recipient (withdraw/deposit receivers, keeper rewards, swap, sweep) reverts with
`StakedPhUSD__RecipientIsOwner`. The fork test asserts the owner's phUSD, USDC and sphUSD balances
are unchanged after every transaction. Keep it that way.
