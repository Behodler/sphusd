// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakedPhUSD} from "../src/StakedPhUSD.sol";
import {MockPhUSD} from "./mocks/MockPhUSD.sol";
import {MockPhlimbo} from "./mocks/MockPhlimbo.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {StakedPhUSDBase} from "./utils/StakedPhUSDBase.t.sol";

/// @notice Random sequences of deposit / withdraw / swap / keeper flushes / emissions.
contract StakedPhUSDHandler is Test {
    StakedPhUSD internal vault;
    MockPhUSD internal phUSD;
    MockPhlimbo internal phlimbo;
    MockERC20 internal usdc;
    address internal keeper;
    address[] internal actors;

    /// @notice Largest share price observed so far (assets per 10**decimals shares).
    uint256 public maxPrice;
    /// @notice Set if any action lowered the share price by more than rounding dust.
    bool public priceDecreased;

    /// @notice Set if a same-block deposit -> swap -> redeem recovered any of the swap price.
    bool public jitExtracted;

    uint256 internal constant DUST = 2;

    constructor(
        StakedPhUSD vault_,
        MockPhUSD phUSD_,
        MockPhlimbo phlimbo_,
        MockERC20 usdc_,
        address keeper_,
        address[] memory actors_
    ) {
        vault = vault_;
        phUSD = phUSD_;
        phlimbo = phlimbo_;
        usdc = usdc_;
        keeper = keeper_;
        actors = actors_;
        maxPrice = _price();
    }

    function _price() internal view returns (uint256) {
        return vault.convertToAssets(10 ** vault.decimals());
    }

    modifier trackPrice() {
        _;
        uint256 p = _price();
        if (p + DUST < maxPrice) priceDecreased = true;
        if (p > maxPrice) maxPrice = p;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amount) external trackPrice {
        address a = _actor(seed);
        amount = bound(amount, 1, 1_000e18);
        vm.prank(a);
        vault.deposit(amount, a);
    }

    function redeem(uint256 seed, uint256 fraction) external trackPrice {
        address a = _actor(seed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(fraction, 1, bal);
        if (vault.previewRedeem(shares) == 0) return;
        vm.prank(a);
        vault.redeem(shares, a, a);
    }

    function withdraw(uint256 seed, uint256 amount) external trackPrice {
        address a = _actor(seed);
        uint256 max = vault.maxWithdraw(a);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        vault.withdraw(amount, a, a);
    }

    function yieldAndSwap(uint256 amount) external trackPrice {
        if (phlimbo.totalStaked() == 0) return;
        amount = bound(amount, 1e6, 100e6);
        usdc.mint(address(this), amount);
        usdc.approve(address(phlimbo), amount);
        phlimbo.distributeStable(amount);
        vm.prank(keeper);
        vault.swap(IERC20(address(usdc)), keeper);
    }

    /// @dev Same-block deposit -> swap -> redeem by one actor. It must never recover any of the
    ///      swap price (proceeds vest; they do not step the share price).
    function jitSwap(uint256 seed, uint256 amount, uint256 usdcAmount) external trackPrice {
        address a = _actor(seed);
        amount = bound(amount, 1, 1_000_000e18);
        usdcAmount = bound(usdcAmount, 1e6, 100e6);
        if (phlimbo.totalStaked() > 0) {
            usdc.mint(address(this), usdcAmount);
            usdc.approve(address(phlimbo), usdcAmount);
            phlimbo.distributeStable(usdcAmount);
        } else {
            usdc.mint(address(vault), usdcAmount);
        }
        uint256 price = vault.swapPrice(address(usdc));
        uint256 start = phUSD.balanceOf(a);
        vm.startPrank(a);
        uint256 shares = vault.deposit(amount, a);
        vault.swap(IERC20(address(usdc)), a);
        if (shares > 0) vault.redeem(shares, a, a);
        vm.stopPrank();
        if (phUSD.balanceOf(a) + price > start) jitExtracted = true;
    }

    /// @dev Let time pass so vesting progresses between other actions.
    function warp(uint256 secs) external trackPrice {
        secs = bound(secs, 1, 3 days);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12 + 1);
    }

    function emission(uint256 amount) external trackPrice {
        if (phlimbo.totalStaked() == 0) return;
        amount = bound(amount, 1, 10e18);
        phlimbo.distributePhUSD(amount);
    }

    function stakePending() external trackPrice {
        if (vault.pendingDeposits() < vault.depositThreshold() || vault.pendingDeposits() == 0) return;
        vm.prank(keeper);
        vault.stakePending(keeper);
    }

    function flushWithdrawals() external trackPrice {
        if (vault.pendingWithdrawals() < vault.withdrawThreshold() || vault.pendingWithdrawals() == 0) return;
        vm.prank(keeper);
        vault.flushWithdrawals(keeper);
    }

    function flushAll() external trackPrice {
        uint256 q = vault.pendingDeposits() + vault.pendingWithdrawals();
        if (q == 0 || q < vault.depositThreshold() + vault.withdrawThreshold()) return;
        vm.prank(keeper);
        vault.flushAll(keeper);
    }
}

contract StakedPhUSDInvariantTest is StakedPhUSDBase {
    StakedPhUSDHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = makeAddr("carol");
        _fund(actors[2], 10_000e18);
        for (uint256 i; i < actors.length; i++) {
            phUSD.mint(actors[i], 1_000_000e18);
        }
        phUSD.mint(keeper, 1_000_000e18);

        handler = new StakedPhUSDHandler(vault, phUSD, phlimbo, usdc, keeper, actors);
        targetContract(address(handler));
    }

    function invariant_totalAssetsIdentity() public view {
        assertEq(vault.stakedInPhlimbo(), _phlimboPosition(), "staked reconciles with Phlimbo");
        assertEq(
            vault.totalAssets(),
            _phlimboPosition() + vault.pendingDeposits() - vault.pendingWithdrawals() - vault.unvestedProceeds(),
            "identity"
        );
        assertLe(
            vault.unvestedProceeds(),
            _phlimboPosition() + vault.pendingDeposits() - vault.pendingWithdrawals(),
            "unvested proceeds are held"
        );
        assertLe(vault.pendingWithdrawals(), _phlimboPosition(), "owed phUSD is still staked");
        assertGe(phUSD.balanceOf(address(vault)), vault.pendingDeposits(), "idle phUSD is held");
    }

    function invariant_sharePriceNeverDecreases() public view {
        assertFalse(handler.priceDecreased(), "share price decreased");
    }

    function invariant_sameBlockJitNeverExtracts() public view {
        assertFalse(handler.jitExtracted(), "same-block deposit/swap/redeem recovered swap price");
    }

    function invariant_solvent() public view {
        // Every outstanding share is redeemable for at most totalAssets.
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets());
    }
}
