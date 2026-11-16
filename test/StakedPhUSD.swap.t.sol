// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {StakedPhUSD} from "../src/StakedPhUSD.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {StakedPhUSDBase} from "./utils/StakedPhUSDBase.t.sol";

/// @notice swap, sweep, owner configuration, pause and the inflation attack.
contract StakedPhUSDSwapAdminTest is StakedPhUSDBase {
    function _staked(uint256 amount) internal {
        _deposit(alice, amount);
        _stakePending();
    }

    // ========================== swap ==========================

    function test_swap_unconfiguredTokenReverts() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__NotSwappable.selector, address(promo)));
        vault.swap(IERC20(address(promo)), keeper);
    }

    function test_swap_zeroBalanceReverts() public {
        _staked(1000e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__NothingToSwap.selector, address(usdc)));
        vault.swap(IERC20(address(usdc)), keeper);
    }

    function test_swap_raisesSharePrice() public {
        _staked(1000e18);
        _distributeUsdc(53e6);
        uint256 priceBefore = _price();
        uint256 assetsBefore = vault.totalAssets();

        vm.prank(keeper);
        uint256 payout = vault.swap(IERC20(address(usdc)), keeper);

        assertEq(payout, 53e6);
        assertEq(usdc.balanceOf(keeper), 53e6);
        assertEq(vault.totalAssets(), assetsBefore + USDC_PRICE);
        assertEq(vault.pendingDeposits(), USDC_PRICE);
        assertGt(_price(), priceBefore, "share price rises");
        _assertAccounting();
    }

    function test_swap_readsBalanceAfterClaim() public {
        _staked(1000e18);
        // Some USDC already sits in the vault (auto-claimed on an earlier stake).
        _distributeUsdc(10e6);
        _deposit(bob, 100e18);
        _stakePending(); // auto-claim drops 10 USDC into the vault
        assertEq(usdc.balanceOf(address(vault)), 10e6);

        _distributeUsdc(40e6); // still pending in Phlimbo
        vm.prank(keeper);
        uint256 payout = vault.swap(IERC20(address(usdc)), keeper);

        // MasterChef accumulator rounding on a 6-decimal reward token loses a few hundred units.
        assertApproxEqAbs(payout, 50e6, 1e3, "held + freshly claimed");
        assertEq(usdc.balanceOf(address(vault)), 0, "whole balance paid out");
        assertEq(phlimbo.pendingStable(address(vault)), 0);
    }

    function test_swap_promoTokensStayAndAreSwappableAtOwnPrice() public {
        _staked(1000e18);
        _distributeUsdc(30e6);
        _distributePromo(500e18);

        vm.prank(keeper);
        vault.swap(IERC20(address(usdc)), keeper);
        assertEq(promo.balanceOf(address(vault)), 500e18, "claim dropped promo, which stays put");
        assertEq(promo.balanceOf(keeper), 0);

        // Not swappable until configured.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__NotSwappable.selector, address(promo)));
        vault.swap(IERC20(address(promo)), keeper);

        vm.prank(owner);
        vault.setSwapPrice(address(promo), PROMO_PRICE);

        uint256 assetsBefore = vault.totalAssets();
        vm.prank(keeper);
        uint256 payout = vault.swap(IERC20(address(promo)), keeper);
        assertEq(payout, 500e18);
        assertEq(promo.balanceOf(keeper), 500e18);
        assertEq(vault.totalAssets(), assetsBefore + PROMO_PRICE);
        _assertAccounting();
    }

    function test_swap_skipsClaimWhilePhlimboPaused() public {
        _staked(1000e18);
        _distributeUsdc(10e6);
        _deposit(bob, 100e18);
        _stakePending(); // 10 USDC now held
        _distributeUsdc(40e6); // pending in Phlimbo
        phlimbo.pause();

        vm.prank(keeper);
        uint256 payout = vault.swap(IERC20(address(usdc)), keeper);
        assertEq(payout, 10e6, "held balance still swappable; claim skipped");
        assertApproxEqAbs(phlimbo.pendingStable(address(vault)), 40e6, 1e3, "pending untouched");
    }

    function test_swap_withNoPositionUsesHeldBalance() public {
        usdc.mint(address(vault), 5e6);
        vm.prank(keeper);
        uint256 payout = vault.swap(IERC20(address(usdc)), keeper);
        assertEq(payout, 5e6);
        assertEq(vault.pendingDeposits(), USDC_PRICE);
    }

    function test_swap_recipientOwnerOrZeroReverts() public {
        usdc.mint(address(vault), 5e6);
        vm.startPrank(keeper);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__RecipientIsOwner.selector);
        vault.swap(IERC20(address(usdc)), owner);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__ZeroAddress.selector);
        vault.swap(IERC20(address(usdc)), address(0));
        vm.stopPrank();
    }

    function test_setSwapPrice_protectedTokensRevert() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__ProtectedToken.selector, address(phUSD)));
        vault.setSwapPrice(address(phUSD), 1e18);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__ProtectedToken.selector, address(vault)));
        vault.setSwapPrice(address(vault), 1e18);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__ZeroAddress.selector);
        vault.setSwapPrice(address(0), 1e18);
        vm.stopPrank();
    }

    function test_setSwapPrice_emitsAndDisables() public {
        vm.expectEmit(address(vault));
        emit StakedPhUSD.SwapPriceUpdated(address(usdc), USDC_PRICE, 0);
        vm.prank(owner);
        vault.setSwapPrice(address(usdc), 0);
        usdc.mint(address(vault), 1e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__NotSwappable.selector, address(usdc)));
        vault.swap(IERC20(address(usdc)), keeper);
    }

    // ========================== keeper recipients ==========================

    function test_keepers_ownerRecipientReverts() public {
        _deposit(alice, 1000e18);
        vm.startPrank(keeper);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__RecipientIsOwner.selector);
        vault.stakePending(owner);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__RecipientIsOwner.selector);
        vault.flushWithdrawals(owner);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__RecipientIsOwner.selector);
        vault.flushAll(owner);
        vm.stopPrank();
    }

    // ========================== sweep ==========================

    function test_sweep_strayToken() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(vault), 7e18);
        address treasury = makeAddr("treasury");
        vm.prank(owner);
        uint256 amount = vault.sweepToken(IERC20(address(stray)), treasury);
        assertEq(amount, 7e18);
        assertEq(stray.balanceOf(treasury), 7e18);
    }

    function test_sweep_refusesProtectedAndConfiguredTokens() public {
        address treasury = makeAddr("treasury");
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__ProtectedToken.selector, address(phUSD)));
        vault.sweepToken(IERC20(address(phUSD)), treasury);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__ProtectedToken.selector, address(vault)));
        vault.sweepToken(IERC20(address(vault)), treasury);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__ConfiguredSwapToken.selector, address(usdc)));
        vault.sweepToken(IERC20(address(usdc)), treasury);
        // Once disabled, it is a stray token again.
        vault.setSwapPrice(address(usdc), 0);
        vault.sweepToken(IERC20(address(usdc)), treasury);
        vm.stopPrank();
    }

    function test_sweep_refusesOwnerAndZeroRecipient() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(vault), 1e18);
        vm.startPrank(owner);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__RecipientIsOwner.selector);
        vault.sweepToken(IERC20(address(stray)), owner);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__ZeroAddress.selector);
        vault.sweepToken(IERC20(address(stray)), address(0));
        vm.stopPrank();
    }

    function test_sweep_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.sweepToken(IERC20(address(promo)), alice);
    }

    // ========================== setters ==========================

    function test_setters_emitEvents() public {
        vm.startPrank(owner);
        vm.expectEmit(address(vault));
        emit StakedPhUSD.DepositThresholdUpdated(DEPOSIT_THRESHOLD, 200e18);
        vault.setDepositThreshold(200e18);
        vm.expectEmit(address(vault));
        emit StakedPhUSD.WithdrawThresholdUpdated(WITHDRAW_THRESHOLD, 200e18);
        vault.setWithdrawThreshold(200e18);
        vm.expectEmit(address(vault));
        emit StakedPhUSD.StakeRewardUpdated(STAKE_REWARD, 2e18);
        vault.setStakeReward(2e18);
        vm.expectEmit(address(vault));
        emit StakedPhUSD.WithdrawFeeUpdated(WITHDRAW_FEE, 2e18);
        vault.setWithdrawFee(2e18);
        vm.expectEmit(address(vault));
        emit StakedPhUSD.FlushAllRewardUpdated(FLUSH_ALL_REWARD, 4e18);
        vault.setFlushAllReward(4e18);
        vm.stopPrank();
    }

    function test_setters_onlyOwner() public {
        vm.startPrank(alice);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(err);
        vault.setDepositThreshold(1);
        vm.expectRevert(err);
        vault.setWithdrawThreshold(1);
        vm.expectRevert(err);
        vault.setStakeReward(1);
        vm.expectRevert(err);
        vault.setWithdrawFee(1);
        vm.expectRevert(err);
        vault.setFlushAllReward(1);
        vm.expectRevert(err);
        vault.setSwapPrice(address(promo), 1);
        vm.expectRevert(err);
        vault.setPauser(alice);
        vm.stopPrank();
    }

    function test_setterCaps_maxReward() public {
        vm.startPrank(owner);
        vault.setDepositThreshold(1000e18);
        vault.setWithdrawThreshold(1000e18);
        uint256 tooHigh = vault.MAX_KEEPER_REWARD() + 1;
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__RewardTooHigh.selector, tooHigh));
        vault.setStakeReward(tooHigh);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__RewardTooHigh.selector, tooHigh));
        vault.setWithdrawFee(tooHigh);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__RewardTooHigh.selector, tooHigh));
        vault.setFlushAllReward(tooHigh);
        vm.stopPrank();
    }

    function test_setterCaps_withdrawFeeVsThreshold() public {
        vm.startPrank(owner);
        vault.setWithdrawThreshold(10e18);
        vm.expectRevert(
            abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__WithdrawFeeAboveThreshold.selector, 10e18 + 1, 10e18)
        );
        vault.setWithdrawFee(10e18 + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                StakedPhUSD.StakedPhUSD__WithdrawFeeAboveThreshold.selector, WITHDRAW_FEE, WITHDRAW_FEE - 1
            )
        );
        vault.setWithdrawThreshold(WITHDRAW_FEE - 1);
        vm.stopPrank();
    }

    function test_setterCaps_stakeRewardVsThreshold() public {
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                StakedPhUSD.StakedPhUSD__StakeRewardAboveThreshold.selector, STAKE_REWARD, STAKE_REWARD - 1
            )
        );
        vault.setDepositThreshold(STAKE_REWARD - 1);
        vm.stopPrank();
    }

    function test_setterCaps_flushAllReward() public {
        vm.startPrank(owner);
        uint256 cap = STAKE_REWARD + WITHDRAW_FEE;
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__FlushAllRewardAboveCap.selector, cap + 1, cap));
        vault.setFlushAllReward(cap + 1);
        vault.setFlushAllReward(cap);
        // Lowering either component below the flushAll reward is refused too.
        vm.expectRevert(
            abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__FlushAllRewardAboveCap.selector, cap, WITHDRAW_FEE)
        );
        vault.setStakeReward(0);
        vm.expectRevert(
            abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__FlushAllRewardAboveCap.selector, cap, STAKE_REWARD)
        );
        vault.setWithdrawFee(0);
        vm.stopPrank();
    }

    // ========================== pause ==========================

    function test_pause_onlyPauser_idempotent() public {
        vm.prank(owner);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__NotPauser.selector);
        vault.pause();

        vm.startPrank(pauserAddr);
        vault.pause();
        vault.pause(); // PauserV2 has no try/catch: must not revert when already paused
        vm.stopPrank();
        assertTrue(vault.paused());
    }

    function test_unpause_ownerOrPauser() public {
        vm.prank(pauserAddr);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__NotPauserOrOwner.selector);
        vault.unpause();
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
        vm.prank(pauserAddr);
        vault.pause();
        vm.prank(pauserAddr);
        vault.unpause();
        vm.prank(pauserAddr);
        vault.unpause(); // idempotent
        assertFalse(vault.paused());
    }

    function test_setPauser_emits() public {
        address np = makeAddr("newPauser");
        vm.expectEmit(address(vault));
        emit StakedPhUSD.PauserChanged(pauserAddr, np);
        vm.prank(owner);
        vault.setPauser(np);
        assertEq(vault.pauser(), np);
    }

    function test_pause_haltsFlowsButNotShareTransfers() public {
        _deposit(alice, 1000e18);
        _stakePending();
        _deposit(alice, 200e18);
        usdc.mint(address(vault), 1e6);
        vm.prank(pauserAddr);
        vault.pause();

        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);

        vm.startPrank(alice);
        vm.expectRevert();
        vault.deposit(1e18, alice);
        vm.expectRevert();
        vault.withdraw(1e18, alice, alice);
        vm.expectRevert();
        vault.redeem(1e21, alice, alice);
        vm.stopPrank();

        vm.startPrank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.stakePending(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.flushWithdrawals(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.flushAll(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.swap(IERC20(address(usdc)), keeper);
        vm.stopPrank();

        // Holders can always move their tokens.
        vm.prank(alice);
        vault.transfer(bob, 10e21);
        assertEq(vault.balanceOf(bob), 10e21);
    }

    function test_phlimboPaused_usersUnaffected() public {
        _deposit(alice, 1000e18);
        _stakePending();
        phlimbo.pause();
        _deposit(bob, 100e18);
        _withdraw(alice, 300e18); // 100 idle + 200 minted
        assertEq(vault.pendingWithdrawals(), 200e18);
        _assertAccounting();
    }

    // ========================== inflation attack ==========================

    function test_inflationAttack_unprofitable() public {
        address attacker = makeAddr("attacker");
        _fund(attacker, 20_000e18);
        uint256 attackerStart = phUSD.balanceOf(attacker);

        // Classic: first deposit 1 wei, then donate a large amount directly.
        _deposit(attacker, 1);
        vm.prank(attacker);
        phUSD.transfer(address(vault), 10_000e18);
        assertEq(vault.totalAssets(), 1, "donations are never counted");

        uint256 victimShares = _deposit(alice, 1000e18);
        assertGt(victimShares, 0);

        uint256 victimOut = _redeem(alice, victimShares);
        assertApproxEqAbs(victimOut, 1000e18, 1, "victim made whole");

        _redeem(attacker, vault.balanceOf(attacker));
        assertLt(phUSD.balanceOf(attacker), attackerStart, "attacker lost the donation");
        assertLe(attackerStart - phUSD.balanceOf(attacker), 10_000e18 + 1);
    }

    function test_inflationAttack_viaSwapUnprofitable() public {
        // An attacker inflates the price through swap instead of a donation.
        address attacker = makeAddr("attacker");
        _fund(attacker, 20_000e18);
        uint256 attackerStart = phUSD.balanceOf(attacker);
        _deposit(attacker, 1);
        usdc.mint(address(vault), 1);
        vm.prank(attacker);
        vault.swap(IERC20(address(usdc)), attacker); // pays USDC_PRICE into the share price

        uint256 victimShares = _deposit(alice, 40e18);
        assertGt(victimShares, 0, "victim still receives shares");
        uint256 victimOut = _redeem(alice, victimShares);
        assertGe(victimOut, 40e18 * 99 / 100, "victim loses < 1%");

        _redeem(attacker, vault.balanceOf(attacker));
        assertLt(phUSD.balanceOf(attacker), attackerStart, "attacker is net down");
    }
}
