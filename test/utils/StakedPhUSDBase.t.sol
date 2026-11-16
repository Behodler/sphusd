// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakedPhUSD} from "../../src/StakedPhUSD.sol";
import {IPhUSD} from "../../src/interfaces/IPhUSD.sol";
import {IPhlimboV3Minimal} from "../../src/interfaces/IPhlimboV3Minimal.sol";
import {MockPhUSD} from "../mocks/MockPhUSD.sol";
import {MockPhlimbo} from "../mocks/MockPhlimbo.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared fixture: mock phUSD / USDC / promo / Phlimbo and a configured vault.
abstract contract StakedPhUSDBase is Test {
    MockPhUSD internal phUSD;
    MockERC20 internal usdc;
    MockERC20 internal promo;
    MockPhlimbo internal phlimbo;
    StakedPhUSD internal vault;

    address internal owner = makeAddr("owner");
    address internal pauserAddr = makeAddr("pauser");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal funder = makeAddr("funder");

    uint256 internal constant DEPOSIT_THRESHOLD = 100e18;
    uint256 internal constant WITHDRAW_THRESHOLD = 100e18;
    uint256 internal constant STAKE_REWARD = 1e18;
    uint256 internal constant WITHDRAW_FEE = 1e18;
    uint256 internal constant FLUSH_ALL_REWARD = 15e17;
    uint256 internal constant USDC_PRICE = 50e18;
    uint256 internal constant PROMO_PRICE = 10e18;

    function setUp() public virtual {
        phUSD = new MockPhUSD();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        promo = new MockERC20("Promo", "PRM", 18);
        phlimbo = new MockPhlimbo(phUSD, IERC20(address(usdc)));

        vault = new StakedPhUSD(
            IPhUSD(address(phUSD)), IPhlimboV3Minimal(address(phlimbo)), IERC20(address(usdc)), owner, pauserAddr
        );

        phUSD.setMinter(address(vault), true);
        phUSD.setMinter(address(phlimbo), true);
        phUSD.setMinter(address(this), true);

        vm.startPrank(owner);
        vault.setDepositThreshold(DEPOSIT_THRESHOLD);
        vault.setWithdrawThreshold(WITHDRAW_THRESHOLD);
        vault.setStakeReward(STAKE_REWARD);
        vault.setWithdrawFee(WITHDRAW_FEE);
        vault.setFlushAllReward(FLUSH_ALL_REWARD);
        vault.setSwapPrice(address(usdc), USDC_PRICE);
        vm.stopPrank();

        _fund(alice, 10_000e18);
        _fund(bob, 10_000e18);
        _fund(keeper, 10_000e18);
    }

    function _fund(address who, uint256 amount) internal {
        phUSD.mint(who, amount);
        vm.prank(who);
        phUSD.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(amount, who);
    }

    function _redeem(address who, uint256 shares) internal returns (uint256 assets) {
        vm.prank(who);
        assets = vault.redeem(shares, who, who);
    }

    function _withdraw(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.withdraw(assets, who, who);
    }

    function _stakePending() internal {
        vm.prank(keeper);
        vault.stakePending(keeper);
    }

    function _distributeUsdc(uint256 amount) internal {
        usdc.mint(funder, amount);
        vm.startPrank(funder);
        usdc.approve(address(phlimbo), amount);
        phlimbo.distributeStable(amount);
        vm.stopPrank();
    }

    function _distributePromo(uint256 amount) internal {
        promo.mint(funder, amount);
        vm.startPrank(funder);
        promo.approve(address(phlimbo), amount);
        phlimbo.distributePromo(IERC20(address(promo)), amount);
        vm.stopPrank();
    }

    function _phlimboPosition() internal view returns (uint256 amount) {
        (amount,,,) = phlimbo.userInfo(address(vault));
    }

    function _assertAccounting() internal view {
        assertEq(vault.stakedInPhlimbo(), _phlimboPosition(), "staked reconciles");
        assertEq(
            vault.totalAssets(),
            _phlimboPosition() + vault.pendingDeposits() - vault.pendingWithdrawals(),
            "totalAssets identity"
        );
        assertGe(phUSD.balanceOf(address(vault)), vault.pendingDeposits(), "idle phUSD backed");
    }

    /// @dev Assets per 1e18 phUSD worth of shares (1 whole share unit of 21 decimals).
    function _price() internal view returns (uint256) {
        return vault.convertToAssets(10 ** vault.decimals());
    }
}
