# sphUSD (Staked PhUSD)

sphUSD is the working name for an ERC20 vault token with name "Staked PhUSD" and symbol "sphUSD". It is an ERC4626-style wrapper that stakes phUSD into PhlimboV3 and compounds the USDC yield into an appreciating share price, giving tax-efficient phUSD staking. This is a source repo only: nothing is deployed from here, and all deployment lives in phase-2-staging.

## Mechanism

- **Deposit / mint** are synchronous. Shares are minted immediately at the current price and the
  phUSD waits in `pendingDeposits` until a keeper stakes it into PhlimboV3.
- **Withdraw / redeem** are synchronous. The phUSD owed is paid from idle `pendingDeposits` first;
  the remainder is minted to the receiver (the vault holds the phUSD minter role) and recorded in
  `pendingWithdrawals`. That amount stays staked, keeps earning USDC for remaining holders, and is
  later unstaked and burnt by a keeper.
- **Yield.** Phlimbo pays USDC (plus any phUSD emission and promo tokens) to the vault on every
  stake, withdraw and claim. Anyone may `swap` the vault's whole balance of a configured reward
  token for an owner-set phUSD price; that phUSD joins the vault's assets and raises the share
  price.
- **Vesting.** Swap proceeds and captured phUSD emissions vest linearly over `VESTING_PERIOD`
  (7 days); a new swap carries the unvested remainder into a fresh schedule. The share price
  therefore rises smoothly, and a just-in-time deposit around a swap (deposit -> swap -> redeem,
  even in one transaction) captures only the slice that vests while it is held.
- **Accounting** is explicit:
  `totalAssets = stakedInPhlimbo + pendingDeposits - pendingWithdrawals - unvestedProceeds()`.
  Donated tokens never move the share price. OZ's decimals offset (3, so sphUSD has 21 decimals)
  defends against the inflation attack.
- Keeper rewards are minted phUSD (or paid from owed phUSD being burnt) and are configured by the
  owner to roughly cover gas. They never come out of holders' assets.

## Keeper functions (permissionless)

| Function | Opens when | Does | Pays the keeper |
|---|---|---|---|
| `stakePending(rewardRecipient)` | `pendingDeposits >= depositThreshold` | nets queues, stakes idle phUSD into Phlimbo (skipped below 1e15) | `stakeReward` |
| `flushWithdrawals(rewardRecipient)` | `pendingWithdrawals >= withdrawThreshold` | nets queues, unstakes the owed phUSD and burns it | `withdrawFee`, out of the burnt phUSD |
| `flushAll(rewardRecipient)` | `pendingDeposits + pendingWithdrawals >= depositThreshold + withdrawThreshold` | both of the above | `flushAllReward` (≤ `stakeReward + withdrawFee`) |
| `swap(token, recipient)` | `swapPrice[token] > 0` | pulls `swapPrice[token]` phUSD, claims Phlimbo, sends the whole `token` balance | the token balance |

All keeper functions revert while sphUSD is paused; those that touch Phlimbo revert while Phlimbo
is paused (`swap` then skips the claim and pays out what is already held).

## Owner configuration

`setDepositThreshold`, `setWithdrawThreshold`, `setStakeReward`, `setWithdrawFee`,
`setFlushAllReward`, `setSwapPrice(token, price)` (0 disables; phUSD and sphUSD are refused),
`setPauser`, and `sweepToken(token, to)` for genuinely stray tokens. Sanity caps: every reward
≤ 100 phUSD, `withdrawFee ≤ withdrawThreshold`, `stakeReward ≤ depositThreshold`,
`flushAllReward ≤ stakeReward + withdrawFee`. No function ever pays the owner.

## Development

```bash
forge build
forge test                                   # the mainnet fork suite is skipped without an RPC
MAINNET_RPC_URL=<archive rpc> forge test
forge fmt --check
```
