// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {StakedPhUSD} from "../src/StakedPhUSD.sol";
import {IPhUSD} from "../src/interfaces/IPhUSD.sol";
import {IPhlimboV3Minimal} from "../src/interfaces/IPhlimboV3Minimal.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPhlimbo} from "./mocks/MockPhlimbo.sol";
import {StakedPhUSDBase} from "./utils/StakedPhUSDBase.t.sol";

/// @notice Deployment, deposit/withdraw flows and the keeper queues.
contract StakedPhUSDCoreTest is StakedPhUSDBase {
    // ========================== deployment ==========================

    function test_metadata() public view {
        assertEq(vault.name(), "Staked PhUSD");
        assertEq(vault.symbol(), "sphUSD");
        assertEq(vault.asset(), address(phUSD));
        assertEq(vault.decimals(), 21, "18 + decimals offset 3");
        assertEq(vault.pauser(), pauserAddr);
        assertEq(vault.owner(), owner);
        assertEq(vault.totalAssets(), 0);
    }

    function test_constructor_zeroAddressReverts() public {
        IPhUSD p = IPhUSD(address(phUSD));
        IPhlimboV3Minimal l = IPhlimboV3Minimal(address(phlimbo));
        IERC20 u = IERC20(address(usdc));
        vm.expectRevert(StakedPhUSD.StakedPhUSD__ZeroAddress.selector);
        new StakedPhUSD(IPhUSD(address(0)), l, u, owner, pauserAddr);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__ZeroAddress.selector);
        new StakedPhUSD(p, IPhlimboV3Minimal(address(0)), u, owner, pauserAddr);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__ZeroAddress.selector);
        new StakedPhUSD(p, l, IERC20(address(0)), owner, pauserAddr);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__ZeroAddress.selector);
        new StakedPhUSD(p, l, u, owner, address(0));
    }

    function test_constructor_phlimboMismatchReverts() public {
        MockERC20 other = new MockERC20("X", "X", 6);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__PhlimboMismatch.selector);
        new StakedPhUSD(
            IPhUSD(address(phUSD)), IPhlimboV3Minimal(address(phlimbo)), IERC20(address(other)), owner, pauserAddr
        );
    }

    // ========================== deposit ==========================

    function test_deposit_mintsSharesAndQueues() public {
        uint256 shares = _deposit(alice, 1000e18);
        assertEq(shares, 1000e21);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.pendingDeposits(), 1000e18);
        assertEq(vault.totalAssets(), 1000e18);
        assertEq(phUSD.balanceOf(address(vault)), 1000e18);
        assertEq(_phlimboPosition(), 0, "nothing staked until a keeper flushes");
        _assertAccounting();
    }

    function test_mint_mintsSharesAndQueues() public {
        vm.prank(alice);
        uint256 assets = vault.mint(500e21, alice);
        assertEq(assets, 500e18);
        assertEq(vault.pendingDeposits(), 500e18);
    }

    function test_deposit_receiverOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__RecipientIsOwner.selector);
        vault.deposit(1e18, owner);
    }

    // ========================== withdraw payment order ==========================

    function test_withdraw_paysFromIdleFirst_noMint() public {
        _deposit(alice, 1000e18);
        uint256 supplyBefore = phUSD.totalSupply();
        uint256 balBefore = phUSD.balanceOf(alice);
        _withdraw(alice, 400e18);
        assertEq(phUSD.balanceOf(alice) - balBefore, 400e18);
        assertEq(phUSD.totalSupply(), supplyBefore, "idle payment mints nothing");
        assertEq(vault.pendingDeposits(), 600e18);
        assertEq(vault.pendingWithdrawals(), 0);
        _assertAccounting();
    }

    function test_withdraw_idleThenMint() public {
        _deposit(alice, 1000e18);
        _stakePending();
        _deposit(bob, 100e18);
        uint256 supplyBefore = phUSD.totalSupply();
        uint256 balBefore = phUSD.balanceOf(alice);

        _withdraw(alice, 300e18);

        assertEq(phUSD.balanceOf(alice) - balBefore, 300e18);
        assertEq(vault.pendingDeposits(), 0, "idle used first");
        assertEq(vault.pendingWithdrawals(), 200e18, "remainder queued");
        assertEq(phUSD.totalSupply() - supplyBefore, 200e18, "remainder minted");
        assertEq(_phlimboPosition(), 1000e18, "queued amount keeps earning in Phlimbo");
        assertEq(vault.totalAssets(), 800e18);
        _assertAccounting();
    }

    function test_withdraw_revertsCleanlyWithoutMinterRole() public {
        _deposit(alice, 1000e18);
        _stakePending();
        _deposit(bob, 100e18);
        phUSD.setMinter(address(vault), false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__MintFailed.selector, alice, 200e18));
        vault.withdraw(300e18, alice, alice);

        // Within the idle buffer it still works.
        _withdraw(alice, 100e18);
        assertEq(vault.pendingDeposits(), 0);
    }

    function test_withdraw_revertsAfterRevokeAllMintPrivileges() public {
        _deposit(alice, 1000e18);
        _stakePending();
        phUSD.revokeAllMintPrivileges();
        vm.prank(alice);
        vm.expectPartialRevert(StakedPhUSD.StakedPhUSD__MintFailed.selector);
        vault.withdraw(1e18, alice, alice);
    }

    function test_withdraw_receiverOwnerReverts() public {
        _deposit(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__RecipientIsOwner.selector);
        vault.withdraw(1e18, owner, alice);
    }

    function test_withdraw_byApprovedSpender() public {
        _deposit(alice, 1000e18);
        vm.prank(alice);
        vault.approve(bob, 100e21);
        vm.prank(bob);
        vault.redeem(100e21, bob, alice);
        assertEq(vault.balanceOf(alice), 900e21);
        assertEq(vault.allowance(alice, bob), 0);
    }

    // ========================== stakePending ==========================

    function test_stakePending_gates() public {
        vm.prank(keeper);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__NothingToFlush.selector);
        vault.stakePending(keeper);

        _deposit(alice, 99e18);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__BelowThreshold.selector, 99e18, DEPOSIT_THRESHOLD)
        );
        vault.stakePending(keeper);
    }

    function test_stakePending_stakesAndRewards() public {
        _deposit(alice, 1000e18);
        uint256 keeperBefore = phUSD.balanceOf(keeper);
        uint256 assetsBefore = vault.totalAssets();

        vm.prank(keeper);
        uint256 staked = vault.stakePending(keeper);

        assertEq(staked, 1000e18);
        assertEq(_phlimboPosition(), 1000e18);
        assertEq(vault.pendingDeposits(), 0);
        assertEq(phUSD.balanceOf(keeper) - keeperBefore, STAKE_REWARD, "minted reward");
        assertEq(vault.totalAssets(), assetsBefore, "reward does not dilute holders");
        _assertAccounting();
    }

    function test_stakePending_netsAgainstWithdrawals() public {
        _deposit(alice, 1000e18);
        _stakePending();
        _withdraw(alice, 300e18); // pw = 300, minted
        _deposit(bob, 200e18); // pd = 200

        uint256 supplyBefore = phUSD.totalSupply();
        uint256 assetsBefore = vault.totalAssets();
        vm.prank(keeper);
        uint256 staked = vault.stakePending(keeper);

        assertEq(staked, 0, "fully netted, nothing staked");
        assertEq(vault.pendingDeposits(), 0);
        assertEq(vault.pendingWithdrawals(), 100e18);
        assertEq(_phlimboPosition(), 1000e18, "no stake-then-burn round trip");
        // 200 netted: 1 paid to the keeper out of the owed phUSD, 199 burnt; nothing minted.
        assertEq(supplyBefore - phUSD.totalSupply(), 199e18);
        assertEq(vault.totalAssets(), assetsBefore);
        _assertAccounting();
    }

    function test_stakePending_skipsBelowPhlimboMinimum() public {
        vm.startPrank(owner);
        vault.setFlushAllReward(0);
        vault.setStakeReward(0);
        vault.setDepositThreshold(0);
        vm.stopPrank();

        _deposit(alice, 1e14);
        vm.prank(keeper);
        uint256 staked = vault.stakePending(keeper);
        assertEq(staked, 0, "skipped, did not revert on Phlimbo's minimum");
        assertEq(vault.pendingDeposits(), 1e14);
        assertEq(_phlimboPosition(), 0);
    }

    function test_stakePending_revertsWhilePhlimboPaused_queueWaits() public {
        _deposit(alice, 1000e18);
        phlimbo.pause();
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.stakePending(keeper);
        assertEq(vault.pendingDeposits(), 1000e18);

        // Users are unaffected.
        _deposit(bob, 10e18);
        _withdraw(alice, 10e18);

        phlimbo.unpause();
        _stakePending();
        assertEq(_phlimboPosition(), 1000e18);
    }

    // ========================== flushWithdrawals ==========================

    function _stakedAndExited(uint256 dep, uint256 exitAssets) internal {
        _deposit(alice, dep);
        _stakePending();
        _withdraw(alice, exitAssets);
    }

    function test_flushWithdrawals_gates() public {
        vm.prank(keeper);
        vm.expectRevert(StakedPhUSD.StakedPhUSD__NothingToFlush.selector);
        vault.flushWithdrawals(keeper);

        _stakedAndExited(1000e18, 50e18);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(StakedPhUSD.StakedPhUSD__BelowThreshold.selector, 50e18, WITHDRAW_THRESHOLD)
        );
        vault.flushWithdrawals(keeper);
    }

    function test_flushWithdrawals_withdrawsBurnsAndPaysFee() public {
        _stakedAndExited(1000e18, 300e18);
        uint256 supplyBefore = phUSD.totalSupply();
        uint256 keeperBefore = phUSD.balanceOf(keeper);
        uint256 assetsBefore = vault.totalAssets();

        vm.prank(keeper);
        uint256 burnt = vault.flushWithdrawals(keeper);

        assertEq(burnt, 300e18 - WITHDRAW_FEE);
        assertEq(phUSD.balanceOf(keeper) - keeperBefore, WITHDRAW_FEE, "fee paid from owed phUSD");
        assertEq(supplyBefore - phUSD.totalSupply(), burnt, "fee is not minted");
        assertEq(_phlimboPosition(), 700e18);
        assertEq(vault.pendingWithdrawals(), 0);
        assertEq(vault.totalAssets(), assetsBefore);
        _assertAccounting();
    }

    function test_flushWithdrawals_netsAgainstDeposits() public {
        _stakedAndExited(1000e18, 300e18);
        _deposit(bob, 50e18); // pd 50, pw 300

        vm.prank(keeper);
        vault.flushWithdrawals(keeper);

        assertEq(vault.pendingDeposits(), 0);
        assertEq(vault.pendingWithdrawals(), 0);
        assertEq(_phlimboPosition(), 750e18, "only the net 250 left Phlimbo");
        _assertAccounting();
    }

    function test_flushWithdrawals_dustRuleExcessGoesToPendingDeposits() public {
        _deposit(alice, 1000e18);
        _stakePending();
        // Leave a remainder of 5e14 (< 1e15) in Phlimbo after the flush.
        _withdraw(alice, 1000e18 - 5e14);
        uint256 assetsBefore = vault.totalAssets();
        assertEq(assetsBefore, 5e14);

        vm.prank(keeper);
        vault.flushWithdrawals(keeper);

        assertEq(_phlimboPosition(), 0, "Phlimbo withdrew the whole position");
        assertEq(vault.stakedInPhlimbo(), 0, "reconciled");
        assertEq(vault.pendingDeposits(), 5e14, "dust excess queued");
        assertEq(vault.totalAssets(), assetsBefore, "dust rule moves no value");
        _assertAccounting();

        // Alice can still redeem her residual shares, paid from idle.
        _redeem(alice, vault.balanceOf(alice));
        assertLe(vault.totalAssets(), 1, "only rounding dust left");
    }

    function test_flushWithdrawals_revertsWhilePhlimboPaused() public {
        _stakedAndExited(1000e18, 300e18);
        phlimbo.pause();
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.flushWithdrawals(keeper);
        assertEq(vault.pendingWithdrawals(), 300e18, "queue waits");
    }

    // ========================== flushAll ==========================

    function test_flushAll_gateCannotBeMetCheaperThanIndividualGates() public {
        // 150 pending deposits clears stakePending's gate but not the aggregate gate.
        _deposit(alice, 150e18);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                StakedPhUSD.StakedPhUSD__BelowThreshold.selector, 150e18, DEPOSIT_THRESHOLD + WITHDRAW_THRESHOLD
            )
        );
        vault.flushAll(keeper);
    }

    function testFuzz_flushAll_gateNeverCheaper(uint256 pd, uint256 pw) public {
        pd = bound(pd, 0, 300e18);
        pw = bound(pw, 0, 300e18);
        _deposit(alice, 1000e18);
        _stakePending();
        if (pw > 0) _withdraw(alice, pw);
        if (pd > 0) _deposit(bob, pd);

        bool aggregateOk = pd + pw >= DEPOSIT_THRESHOLD + WITHDRAW_THRESHOLD && pd + pw > 0;
        vm.prank(keeper);
        if (aggregateOk) {
            vault.flushAll(keeper);
            assertEq(vault.pendingWithdrawals(), 0);
        } else {
            vm.expectRevert();
            vault.flushAll(keeper);
        }
        // Whenever flushAll opened, the combined queue was at least the combined thresholds,
        // i.e. at least what the cheaper of the two individual gates requires.
        if (aggregateOk) assertGe(pd + pw, DEPOSIT_THRESHOLD);
    }

    function test_flushAll_depositsOnly_mintsReward() public {
        _deposit(alice, 250e18);
        uint256 keeperBefore = phUSD.balanceOf(keeper);
        vm.prank(keeper);
        (uint256 staked, uint256 withdrawn) = vault.flushAll(keeper);
        assertEq(staked, 250e18);
        assertEq(withdrawn, 0);
        assertEq(phUSD.balanceOf(keeper) - keeperBefore, FLUSH_ALL_REWARD);
        _assertAccounting();
    }

    function test_flushAll_bothQueues_rewardPaidFromOwedFirst() public {
        _stakedAndExited(1000e18, 300e18);
        _deposit(bob, 50e18);
        uint256 supplyBefore = phUSD.totalSupply();
        uint256 keeperBefore = phUSD.balanceOf(keeper);
        uint256 assetsBefore = vault.totalAssets();

        vm.prank(keeper);
        (uint256 staked, uint256 withdrawn) = vault.flushAll(keeper);

        assertEq(staked, 0);
        assertEq(withdrawn, 250e18);
        assertEq(phUSD.balanceOf(keeper) - keeperBefore, FLUSH_ALL_REWARD, "single reward");
        assertEq(supplyBefore - phUSD.totalSupply(), 300e18 - FLUSH_ALL_REWARD, "nothing minted");
        assertEq(vault.pendingDeposits(), 0);
        assertEq(vault.pendingWithdrawals(), 0);
        assertEq(_phlimboPosition(), 750e18);
        assertEq(vault.totalAssets(), assetsBefore);
        _assertAccounting();
    }

    // ========================== emissions ==========================

    function test_emissions_compoundOnStake() public {
        _deposit(alice, 1000e18);
        _stakePending();
        phlimbo.distributePhUSD(10e18);
        uint256 priceBefore = _price();

        _deposit(bob, 200e18);
        _stakePending(); // Phlimbo auto-claims to the vault on stake

        assertEq(_phlimboPosition(), 1200e18);
        assertEq(vault.pendingDeposits(), 10e18, "emission captured into pendingDeposits");
        assertEq(vault.unvestedProceeds(), 10e18, "emission vests");
        _vestAll();
        assertGt(_price(), priceBefore, "emission compounds into the share price");
        _assertAccounting();
    }

    function test_emissions_capturedOnFlushWithdrawals() public {
        _stakedAndExited(1000e18, 300e18);
        phlimbo.distributePhUSD(7e18);
        vm.prank(keeper);
        vault.flushWithdrawals(keeper);
        assertEq(vault.pendingDeposits(), 7e18);
        assertEq(_phlimboPosition(), 700e18);
        _assertAccounting();
    }

    function test_emissions_capturedOnSwapClaim() public {
        _deposit(alice, 1000e18);
        _stakePending();
        _distributeUsdc(60e6);
        phlimbo.distributePhUSD(3e18);
        vm.prank(keeper);
        vault.swap(IERC20(address(usdc)), keeper);
        assertEq(vault.pendingDeposits(), USDC_PRICE + 3e18);
        _assertAccounting();
    }
}
