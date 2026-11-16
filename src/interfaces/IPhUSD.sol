// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IPhUSD
/// @notice Minimal phUSD (FlaxToken, flax-token-v2) surface used by StakedPhUSD.
/// @dev Mainnet phUSD: 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605 (18 decimals).
///      `mint` is permissioned: the caller must be an authorised minter for the current
///      `mintVersion`. `burn` spends the caller's allowance over `holder`, so a self-burn
///      needs `approve(address(this), amount)` first.
interface IPhUSD is IERC20 {
    /// @notice Mint `amount` phUSD to `recipient`. Reverts unless the caller is an authorised minter.
    /// @param recipient The receiver of the minted phUSD.
    /// @param amount The amount to mint.
    function mint(address recipient, uint256 amount) external;

    /// @notice Burn `amount` phUSD from `holder`, spending the caller's allowance over `holder`.
    /// @param holder The address whose phUSD is burnt.
    /// @param amount The amount to burn.
    function burn(address holder, uint256 amount) external;
}
