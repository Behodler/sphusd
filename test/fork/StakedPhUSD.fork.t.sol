// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakedPhUSD} from "../../src/StakedPhUSD.sol";
import {IPhUSD} from "../../src/interfaces/IPhUSD.sol";
import {IPhlimboV3Minimal} from "../../src/interfaces/IPhlimboV3Minimal.sol";
import {MainnetAddresses as A} from "./MainnetAddresses.sol";

interface IPhUSDAdmin {
    function setMinter(address minter, bool canMint) external;
    function owner() external view returns (address);
}

interface IPhlimboAdmin {
    function collectReward(uint256 amount) external;
    function owner() external view returns (address);
    function promoToken() external view returns (address);
}

/// @title StakedPhUSDForkTest
/// @notice deposit -> stakePending -> yield -> swap -> redeem -> flushWithdrawals against the live
///         PhlimboV3 / phUSD / USDC at a pinned block. Never broadcasts: fork + pranks only.
///         The owner EOA's phUSD, USDC and sphUSD balances are asserted unchanged after every tx.
/// @dev Run with `MAINNET_RPC_URL` set to an archive-capable endpoint:
///        MAINNET_RPC_URL=<archive rpc> forge test --match-path test/fork/StakedPhUSD.fork.t.sol -vv
///      Without `MAINNET_RPC_URL` every test in this contract is skipped (reported as skipped, not passed).
contract StakedPhUSDForkTest is Test {
    IPhUSD internal phUSD = IPhUSD(A.PHUSD);
    IPhlimboV3Minimal internal phlimbo = IPhlimboV3Minimal(A.PHLIMBO_V3);
    IERC20 internal usdc = IERC20(A.USDC);
    StakedPhUSD internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal yieldFunder = makeAddr("yieldFunder");
    address internal funder = makeAddr("phUSDFunder");

    uint256 internal ownerPhUSD;
    uint256 internal ownerUSDC;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("MAINNET_RPC_URL unset: skipping the mainnet fork suite");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.rpcUrl("mainnet"), A.PINNED_BLOCK);

        // Sanity-check the pinned addresses.
        assertEq(phlimbo.phUSD(), A.PHUSD, "phlimbo.phUSD");
        assertEq(phlimbo.rewardToken(), A.USDC, "phlimbo.rewardToken");
        assertFalse(phlimbo.paused(), "phlimbo unpaused at pin");
        assertEq(IPhUSDAdmin(A.PHUSD).owner(), A.OWNER_EOA, "phUSD owner");
        assertGt(A.PAUSER_V2.code.length, 0, "PauserV2 has code");

        ownerPhUSD = phUSD.balanceOf(A.OWNER_EOA);
        ownerUSDC = usdc.balanceOf(A.OWNER_EOA);

        vault = new StakedPhUSD(phUSD, phlimbo, usdc, A.OWNER_EOA, A.PAUSER_V2);
        _checkOwner();

        // Simulated operational grants (the human broadcasts these for real). Pranks move no funds.
        vm.startPrank(A.OWNER_EOA);
        IPhUSDAdmin(A.PHUSD).setMinter(address(vault), true);
        IPhUSDAdmin(A.PHUSD).setMinter(funder, true);
        vault.setDepositThreshold(500e18);
        vault.setWithdrawThreshold(100e18);
        vault.setStakeReward(1e18);
        vault.setWithdrawFee(1e18);
        vault.setFlushAllReward(15e17);
        vault.setSwapPrice(A.USDC, 1e18);
        vm.stopPrank();
        _checkOwner();

        // Fund users by minting with a pranked minter (never via the owner EOA).
        vm.startPrank(funder);
        phUSD.mint(alice, 10_000e18);
        phUSD.mint(bob, 10_000e18);
        phUSD.mint(keeper, 1_000e18);
        vm.stopPrank();
        _checkOwner();

        vm.prank(alice);
        phUSD.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        phUSD.approve(address(vault), type(uint256).max);
        vm.prank(keeper);
        phUSD.approve(address(vault), type(uint256).max);
    }

    function _checkOwner() internal view {
        assertEq(phUSD.balanceOf(A.OWNER_EOA), ownerPhUSD, "owner phUSD unchanged");
        assertEq(usdc.balanceOf(A.OWNER_EOA), ownerUSDC, "owner USDC unchanged");
        if (address(vault) != address(0)) assertEq(vault.balanceOf(A.OWNER_EOA), 0, "owner holds no sphUSD");
    }

    function _position() internal view returns (uint256 amount) {
        (amount,,,) = phlimbo.userInfo(address(vault));
    }

    function test_fork_fullLifecycle() public {
        // 1. deposit
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(5_000e18, alice);
        _checkOwner();
        vm.prank(bob);
        vault.deposit(1_000e18, bob);
        _checkOwner();
        assertEq(vault.pendingDeposits(), 6_000e18);

        // 2. stakePending into the live PhlimboV3
        vm.prank(keeper);
        vault.stakePending(keeper);
        _checkOwner();
        assertEq(_position(), 6_000e18, "staked into Phlimbo");
        assertEq(vault.stakedInPhlimbo(), 6_000e18);
        assertEq(vault.pendingDeposits(), 0);

        // 3. yield: a funded account calls the permissionless collectReward, then time passes
        deal(A.USDC, yieldFunder, 10_000e6);
        vm.startPrank(yieldFunder);
        usdc.approve(A.PHLIMBO_V3, 10_000e6);
        IPhlimboAdmin(A.PHLIMBO_V3).collectReward(10_000e6);
        vm.stopPrank();
        _checkOwner();
        vm.warp(block.timestamp + 7 days);
        uint256 pending = phlimbo.pendingStable(address(vault));
        assertGt(pending, 0, "vault accrued USDC");

        // 4. swap: keeper pays 1 phUSD for the accrued USDC; share price rises
        uint256 priceBefore = vault.convertToAssets(1e21);
        vm.prank(keeper);
        uint256 payout = vault.swap(usdc, keeper);
        _checkOwner();
        assertGe(payout, pending, "payout includes the freshly claimed USDC");
        assertEq(usdc.balanceOf(keeper), payout);
        assertGt(vault.convertToAssets(1e21), priceBefore, "share price rose");
        console2.log("USDC paid to keeper (6dp):", payout);

        // 5. redeem: alice exits, paid from idle first then minted
        uint256 aliceBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(aliceShares, alice, alice);
        _checkOwner();
        assertGt(out, 5_000e18, "alice earned yield");
        assertEq(phUSD.balanceOf(alice) - aliceBefore, out);
        assertGt(vault.pendingWithdrawals(), 0);
        assertEq(_position(), 6_000e18, "queued exit still earning in Phlimbo");

        // 6. flushWithdrawals: unstake from live Phlimbo and burn
        uint256 owed = vault.pendingWithdrawals();
        uint256 supplyBefore = phUSD.totalSupply();
        uint256 assetsBefore = vault.totalAssets();
        vm.prank(keeper);
        uint256 burnt = vault.flushWithdrawals(keeper);
        _checkOwner();
        assertEq(vault.pendingWithdrawals(), 0);
        assertEq(_position(), 6_000e18 - owed);
        assertEq(burnt, owed - 1e18);
        assertLe(phUSD.totalSupply(), supplyBefore - burnt, "owed phUSD burnt");
        assertEq(vault.totalAssets(), assetsBefore, "flush moves no holder value");

        // Bob is still whole and can exit.
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 bobOut = vault.redeem(bobShares, bob, bob);
        _checkOwner();
        assertGt(bobOut, 1_000e18);
    }

    function test_fork_pauserV2CanPauseIdempotently() public {
        vm.startPrank(A.PAUSER_V2);
        vault.pause();
        vault.pause();
        vm.stopPrank();
        assertTrue(vault.paused());
        _checkOwner();
    }
}
