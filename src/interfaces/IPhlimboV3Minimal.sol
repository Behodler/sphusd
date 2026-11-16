// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPhlimboV3Minimal
/// @notice Trimmed PhlimboV3 interface: only the functions and views StakedPhUSD uses.
/// @dev Vendored from `Behodler/phlimbo-ea` `src/PhlimboV3.sol` / `src/interfaces/IPhlimboV3.sol`
///      at commit f279c627313cf8a9dffa7c4af62b6bdf56bd593d (the commit phase-2-staging pins as
///      `lib/phlimbo-ea`). Mainnet PhlimboV3: 0x8D3A8E3ba43DEb8C7e2110DF437a92243523b6ca.
///
///      Behaviour relied upon (see PhlimboV3 at that commit):
///      - `stake(amount, user)` requires `msg.sender == user`, `amount >= MINIMUM_STAKE (1e15)`,
///        pulls phUSD from the caller, and auto-claims pending rewards to the caller when the
///        position is non-zero.
///      - `withdraw(amount, user)` auto-claims, then sends phUSD to the caller. Dust rule: if the
///        remainder would be in (0, 1e15) the WHOLE position is withdrawn.
///      - `claim(user)` sends pending rewards to the caller.
///      - Rewards are USDC (`rewardToken`), minted phUSD (APY emission) and an optional promo
///        token. USDC to a blocklisted recipient is banked in `unclaimableStableOf` (ignored here).
///      - stake / withdraw / claim are `whenNotPaused`.
interface IPhlimboV3Minimal {
    /// @notice Stake `amount` phUSD for `user` (must equal msg.sender).
    function stake(uint256 amount, address user) external;

    /// @notice Withdraw `amount` staked phUSD for `user` (must equal msg.sender), auto-claiming rewards.
    function withdraw(uint256 amount, address user) external;

    /// @notice Claim pending rewards for `user` (must equal msg.sender).
    function claim(address user) external;

    /// @notice Per-user position: staked amount and reward debts.
    function userInfo(address user)
        external
        view
        returns (uint256 amount, uint256 phUSDDebt, uint256 stableDebt, uint256 promoDebt);

    /// @notice Pending USDC reward for `user`.
    function pendingStable(address user) external view returns (uint256);

    /// @notice Pending phUSD emission for `user`.
    function pendingPhUSD(address user) external view returns (uint256);

    /// @notice Pending promo-token reward for `user`.
    function pendingPromo(address user) external view returns (uint256);

    /// @notice Total phUSD staked across all users.
    function totalStaked() external view returns (uint256);

    /// @notice The stable reward token (USDC on mainnet).
    function rewardToken() external view returns (address);

    /// @notice The staked token (phUSD).
    function phUSD() external view returns (address);

    /// @notice Whether Phlimbo is paused (global pause or promo rotation).
    function paused() external view returns (bool);

    /// @notice Minimum stake amount (1e15).
    function MINIMUM_STAKE() external view returns (uint256);
}
