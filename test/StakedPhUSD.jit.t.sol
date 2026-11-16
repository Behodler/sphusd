// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakedPhUSDBase} from "./utils/StakedPhUSDBase.t.sol";

/// @notice Just-in-time capture of swap proceeds and emissions (review finding, story 001 attempt 2).
/// @dev Swap proceeds and captured emissions vest linearly over `VESTING_PERIOD`, so a deposit made
///      around a swap earns only the slice that vests while it is held.
contract StakedPhUSDJitTest is StakedPhUSDBase {
    address internal attacker = makeAddr("attacker");

    function _aliceStakedWithAccruedUsdc(uint256 stake, uint256 usdcAccrued) internal {
        _deposit(alice, stake);
        _stakePending();
        _distributeUsdc(usdcAccrued);
    }

    /// @dev The reviewer's PoC: alice 1,000 phUSD staked, 1,000 USDC accrued, price 50, attacker
    ///      1,000,000 phUSD doing deposit -> swap -> redeem in one transaction.
    function test_jit_reviewerPoC_sameTxCapturesNothing() public {
        _aliceStakedWithAccruedUsdc(1000e18, 1000e6);
        _fund(attacker, 1_000_000e18 + USDC_PRICE);
        uint256 attackerStart = phUSD.balanceOf(attacker);
        uint256 aliceShares = vault.balanceOf(alice);

        vm.startPrank(attacker);
        uint256 shares = vault.deposit(1_000_000e18, attacker);
        uint256 payout = vault.swap(IERC20(address(usdc)), attacker);
        vault.redeem(shares, attacker, attacker);
        vm.stopPrank();

        assertApproxEqAbs(payout, 1000e6, 1e3, "attacker bought the USDC");
        uint256 cost = attackerStart - phUSD.balanceOf(attacker);
        assertGe(cost, USDC_PRICE, "attacker pays the full swap price; recovers none of it");
        assertLe(cost, USDC_PRICE + 1, "and loses at most rounding dust beyond it");

        // The proceeds vest to the holder who stayed.
        _vestAll();
        assertEq(vault.balanceOf(alice), aliceShares);
        assertApproxEqAbs(vault.convertToAssets(aliceShares), 1000e18 + USDC_PRICE, 1e6, "alice receives the proceeds");
        _assertAccounting();
    }

    /// @dev Front-running an honest keeper: attacker deposits, keeper swaps, attacker redeems one
    ///      block later. The attacker earns only one block of vesting on its share of the vault.
    function test_jit_frontRunKeeperSwap_boundedByOneBlockOfVesting() public {
        _aliceStakedWithAccruedUsdc(1000e18, 1000e6);
        _fund(attacker, 1_000_000e18);
        uint256 attackerStart = phUSD.balanceOf(attacker);

        uint256 shares = _deposit(attacker, 1_000_000e18);
        vm.prank(keeper);
        vault.swap(IERC20(address(usdc)), keeper);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _redeem(attacker, shares);

        uint256 end = phUSD.balanceOf(attacker);
        uint256 gain = end > attackerStart ? end - attackerStart : 0;
        uint256 oneBlockOfVesting = USDC_PRICE * 12 / vault.VESTING_PERIOD() + 1;
        assertLe(gain, oneBlockOfVesting, "gain bounded by one block of vesting");
        assertLt(gain, USDC_PRICE / 10_000, "under 0.01% of the swap price");

        _vestAll();
        assertApproxEqRel(
            vault.convertToAssets(vault.balanceOf(alice)), 1000e18 + USDC_PRICE, 1e14, "alice keeps ~all proceeds"
        );
        _assertAccounting();
    }

    /// @dev Same step-function check for captured Phlimbo phUSD emissions.
    function test_jit_emissionCaptureSameTxCapturesNothing() public {
        _deposit(alice, 1000e18);
        _stakePending();
        phlimbo.distributePhUSD(10e18);
        _fund(attacker, 1_000_000e18);
        uint256 attackerStart = phUSD.balanceOf(attacker);

        uint256 shares = _deposit(attacker, 1_000_000e18);
        _stakePending(); // Phlimbo auto-claims the emission into the vault
        assertEq(vault.unvestedProceeds(), 10e18, "emission vests");
        _redeem(attacker, shares);

        assertLe(phUSD.balanceOf(attacker), attackerStart, "attacker gains nothing from the emission");
        _vestAll();
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1010e18, 1e6, "alice receives the emission");
        _assertAccounting();
    }

    /// @dev Vesting carries the unvested remainder into a fresh schedule without moving the price.
    function test_vesting_newProceedsCarryRemainderWithoutPriceJump() public {
        _aliceStakedWithAccruedUsdc(1000e18, 100e6);
        vm.prank(keeper);
        vault.swap(IERC20(address(usdc)), keeper);

        vm.warp(block.timestamp + vault.VESTING_PERIOD() / 4);
        uint256 assetsBefore = vault.totalAssets();
        uint256 unvestedBefore = vault.unvestedProceeds();
        assertApproxEqAbs(unvestedBefore, USDC_PRICE * 3 / 4, 1);

        _distributeUsdc(100e6);
        vm.prank(keeper);
        vault.swap(IERC20(address(usdc)), keeper);

        assertEq(vault.totalAssets(), assetsBefore, "no step on a new swap");
        assertEq(vault.unvestedProceeds(), unvestedBefore + USDC_PRICE, "remainder carried");
        assertEq(vault.vestingEnd(), block.timestamp + vault.VESTING_PERIOD());

        _vestAll();
        assertApproxEqAbs(vault.totalAssets(), 1000e18 + 2 * USDC_PRICE, 1, "everything vests");
        _assertAccounting();
    }

    /// @dev Any deposit size, stake and accrual: deposit -> swap -> redeem in one block never recovers
    ///      any of the swap price.
    function testFuzz_jit_sameBlockNeverRecoversSwapPrice(uint256 stake, uint256 attackAmount, uint256 usdcAccrued)
        public
    {
        stake = bound(stake, DEPOSIT_THRESHOLD, 1_000_000e18);
        attackAmount = bound(attackAmount, 1, 1_000_000_000e18);
        usdcAccrued = bound(usdcAccrued, 1e6, 1_000_000e6);
        phUSD.mint(alice, stake);
        _aliceStakedWithAccruedUsdc(stake, usdcAccrued);
        _fund(attacker, attackAmount + USDC_PRICE);
        uint256 attackerStart = phUSD.balanceOf(attacker);

        vm.startPrank(attacker);
        uint256 shares = vault.deposit(attackAmount, attacker);
        vault.swap(IERC20(address(usdc)), attacker);
        if (shares > 0) vault.redeem(shares, attacker, attacker);
        vm.stopPrank();

        assertLe(phUSD.balanceOf(attacker) + USDC_PRICE, attackerStart, "no part of the swap price recovered");
        _assertAccounting();
    }
}
