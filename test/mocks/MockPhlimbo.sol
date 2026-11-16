// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockPhUSD} from "./MockPhUSD.sol";

/// @title MockPhlimbo
/// @notice A faithful-in-shape PhlimboV3 (phlimbo-ea @ f279c62) for unit tests:
///         - MasterChef accumulators for USDC, minted-phUSD emission and an optional promo token;
///         - auto-claim to msg.sender on stake (non-zero position), withdraw and claim;
///         - `msg.sender == user` auth, `MINIMUM_STAKE = 1e15`, the dust full-withdraw rule;
///         - `whenNotPaused` on stake / withdraw / claim;
///         - a failing phUSD emission mint is banked, not reverted (as V3 does).
///         Rewards are injected by test helpers (`distributeStable`, `distributePhUSD`,
///         `distributePromo`) instead of a time-based stream.
contract MockPhlimbo is Pausable {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount;
        uint256 phUSDDebt;
        uint256 stableDebt;
        uint256 promoDebt;
    }

    uint256 public constant MINIMUM_STAKE = 1e15;
    uint256 public constant PRECISION = 1e18;

    MockPhUSD public immutable phUSDToken;
    IERC20 public immutable stable;
    IERC20 public promoToken;

    uint256 public totalStaked;
    uint256 public accPhUSDPerShare;
    uint256 public accStablePerShare;
    uint256 public accPromoPerShare;
    mapping(address => UserInfo) public userInfo;
    mapping(address => uint256) public unclaimablePhUSDOf;

    constructor(MockPhUSD phUSD_, IERC20 stable_) {
        phUSDToken = phUSD_;
        stable = stable_;
    }

    function phUSD() external view returns (address) {
        return address(phUSDToken);
    }

    function rewardToken() external view returns (address) {
        return address(stable);
    }

    // ---- test helpers ----

    function pause() external {
        _pause();
    }

    function unpause() external {
        _unpause();
    }

    /// @notice Pull `amount` USDC from the caller and distribute it pro rata to current stakers.
    function distributeStable(uint256 amount) external {
        require(totalStaked > 0, "no stakers");
        stable.safeTransferFrom(msg.sender, address(this), amount);
        accStablePerShare += (amount * PRECISION) / totalStaked;
    }

    /// @notice Accrue `amount` phUSD emission (minted at claim time) pro rata.
    function distributePhUSD(uint256 amount) external {
        require(totalStaked > 0, "no stakers");
        accPhUSDPerShare += (amount * PRECISION) / totalStaked;
    }

    /// @notice Start (or top up) a promotion with `token`, distributing `amount` pro rata now.
    function distributePromo(IERC20 token, uint256 amount) external {
        require(totalStaked > 0, "no stakers");
        if (address(promoToken) == address(0)) promoToken = token;
        require(address(promoToken) == address(token), "one promo at a time");
        token.safeTransferFrom(msg.sender, address(this), amount);
        accPromoPerShare += (amount * PRECISION) / totalStaked;
    }

    // ---- core ----

    function stake(uint256 amount, address user) external whenNotPaused {
        require(amount >= MINIMUM_STAKE, "Below minimum stake");
        require(msg.sender == user, "Not authorized");
        UserInfo storage u = userInfo[user];
        if (u.amount > 0) _claimRewards(user, msg.sender);
        IERC20(address(phUSDToken)).safeTransferFrom(msg.sender, address(this), amount);
        u.amount += amount;
        _realign(u);
        totalStaked += amount;
    }

    function withdraw(uint256 amount, address user) external whenNotPaused {
        require(msg.sender == user, "Not authorized");
        UserInfo storage u = userInfo[user];
        require(u.amount >= amount, "Insufficient balance");
        _claimRewards(user, msg.sender);
        uint256 remaining = u.amount - amount;
        uint256 actual = amount;
        if (remaining > 0 && remaining < MINIMUM_STAKE) {
            actual = u.amount;
            remaining = 0;
        }
        u.amount = remaining;
        _realign(u);
        totalStaked -= actual;
        IERC20(address(phUSDToken)).safeTransfer(msg.sender, actual);
    }

    function claim(address user) external whenNotPaused {
        require(msg.sender == user, "Not authorized");
        _claimRewards(user, msg.sender);
        _realign(userInfo[user]);
    }

    // ---- views ----

    function pendingStable(address user) external view returns (uint256) {
        UserInfo storage u = userInfo[user];
        return (u.amount * accStablePerShare) / PRECISION - u.stableDebt;
    }

    function pendingPhUSD(address user) external view returns (uint256) {
        UserInfo storage u = userInfo[user];
        return (u.amount * accPhUSDPerShare) / PRECISION - u.phUSDDebt;
    }

    function pendingPromo(address user) external view returns (uint256) {
        UserInfo storage u = userInfo[user];
        return (u.amount * accPromoPerShare) / PRECISION - u.promoDebt;
    }

    // ---- internal ----

    function _realign(UserInfo storage u) internal {
        u.phUSDDebt = (u.amount * accPhUSDPerShare) / PRECISION;
        u.stableDebt = (u.amount * accStablePerShare) / PRECISION;
        u.promoDebt = (u.amount * accPromoPerShare) / PRECISION;
    }

    function _claimRewards(address user, address beneficiary) internal {
        UserInfo storage u = userInfo[user];
        if (u.amount == 0) return;
        uint256 ph = (u.amount * accPhUSDPerShare) / PRECISION - u.phUSDDebt;
        if (ph > 0) {
            try phUSDToken.mint(beneficiary, ph) {}
            catch {
                unclaimablePhUSDOf[beneficiary] += ph;
            }
        }
        uint256 st = (u.amount * accStablePerShare) / PRECISION - u.stableDebt;
        if (st > 0) stable.safeTransfer(beneficiary, st);
        if (address(promoToken) != address(0)) {
            uint256 pr = (u.amount * accPromoPerShare) / PRECISION - u.promoDebt;
            if (pr > 0) promoToken.safeTransfer(beneficiary, pr);
        }
    }
}
