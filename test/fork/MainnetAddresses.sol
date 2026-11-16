// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MainnetAddresses
/// @notice Ethereum mainnet addresses the StakedPhUSD fork suite uses. Each is sanity-checked on the
///         fork by `StakedPhUSDForkTest.setUp`.
/// @dev Provenance: "mainnet-addresses.ts" = `phase-2-staging/server/deployments/mainnet-addresses.ts`
///      (read-only, hand-maintained); "fork" = read on the fork at `PINNED_BLOCK`.
library MainnetAddresses {
    /// @notice Recent mainnet block the fork suite pins (2026-11-16 00:29:23 UTC, timestamp 1794788963).
    ///         PhlimboV3 is unpaused with no promo token and no hook at this block.
    uint256 internal constant PINNED_BLOCK = 26_424_000;

    // --- Phoenix (mainnet-addresses.ts) ---
    address internal constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address internal constant PHLIMBO_V3 = 0x8D3A8E3ba43DEb8C7e2110DF437a92243523b6ca;
    /// @dev Calls PhlimboV3.collectReward (USDC yield source).
    address internal constant STABLE_YIELD_ACCUMULATOR = 0x9d69c68F354575B95c1ebf7E87DB85BF3BFF2cE8;
    /// @dev PauserV2 (story 128).
    address internal constant PAUSER_V2 = 0x669Ebfa5309db66683c199Cfe22516DECBe1a154;

    // --- Tokens (mainnet-addresses.ts) ---
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // --- Owner (fork: phUSD.owner() and PhlimboV3.owner()) ---
    /// @dev The human's Ledger. Pays gas only; no funds may ever reach it.
    address internal constant OWNER_EOA = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
}
