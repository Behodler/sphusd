// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPausable} from "./interfaces/IPausable.sol";
import {IPhUSD} from "./interfaces/IPhUSD.sol";
import {IPhlimboV3Minimal} from "./interfaces/IPhlimboV3Minimal.sol";

/// @title StakedPhUSD ("Staked PhUSD", sphUSD)
/// @notice ERC4626 vault over phUSD that stakes into PhlimboV3 as one vault-owned position and
///         compounds Phlimbo's rewards into an appreciating share price. Holders own an
///         appreciating token instead of receiving USDC claims.
/// @dev Mechanism:
///      - deposit/mint are synchronous: shares are minted at once and the phUSD is queued in
///        `pendingDeposits` until a keeper calls `stakePending`.
///      - withdraw/redeem are synchronous: the phUSD owed is paid from idle `pendingDeposits`
///        first, and the remainder is MINTED to the receiver (the vault needs the phUSD minter
///        role) and queued in `pendingWithdrawals`. That queued amount is still staked in Phlimbo
///        and keeps earning until a keeper calls `flushWithdrawals`, which unstakes and burns it.
///      - `swap(token, recipient)` sells the vault's whole balance of a configured reward token
///        (USDC first, Phlimbo promo tokens as configured) for an owner-set phUSD price; that phUSD
///        joins `pendingDeposits` and lifts the share price.
///      - Accounting is explicit: `totalAssets() = stakedInPhlimbo + pendingDeposits -
///        pendingWithdrawals`. Donated phUSD is never counted.
///      - Keeper rewards are minted phUSD (inflationary, by design) or paid out of owed phUSD that
///        is being burnt anyway, so no keeper reward is ever paid out of holders' assets.
///      - No code path pays any token to `owner()`.
contract StakedPhUSD is ERC4626, Ownable, Pausable, ReentrancyGuard, IPausable {
    using SafeERC20 for IERC20;

    // ========================== CONSTANTS ==========================

    /// @notice Phlimbo's minimum stake. Stakes below it are skipped, never attempted.
    uint256 public constant PHLIMBO_MINIMUM_STAKE = 1e15;

    /// @notice Upper bound for every keeper reward / fee setter (fat-finger guard).
    uint256 public constant MAX_KEEPER_REWARD = 100e18;

    /// @dev Decimals offset for OZ's virtual-share inflation-attack defence (sphUSD has 21 decimals).
    uint8 private constant DECIMALS_OFFSET = 3;

    // ========================== IMMUTABLES ==========================

    /// @notice The phUSD token (the vault asset).
    IPhUSD public immutable phUSD;

    /// @notice The PhlimboV3 staking contract the vault stakes into.
    IPhlimboV3Minimal public immutable phlimbo;

    /// @notice USDC, Phlimbo's stable reward token. Informational; swappability is per `swapPrice`.
    IERC20 public immutable usdc;

    // ========================== STATE ==========================

    /// @notice Idle phUSD held by the vault, waiting to be staked into Phlimbo.
    /// @dev Includes user deposits, phUSD paid in by swappers and captured Phlimbo emissions.
    uint256 public pendingDeposits;

    /// @notice phUSD still staked in Phlimbo that is owed to nobody: exiting users were already
    ///         paid (by mint). It must still be unstaked and burnt.
    uint256 public pendingWithdrawals;

    /// @notice The vault's staked Phlimbo position, reconciled from `phlimbo.userInfo` after every
    ///         Phlimbo call (absorbs the dust rule).
    uint256 public stakedInPhlimbo;

    /// @notice `stakePending` (and `flushAll`) open once `pendingDeposits` reaches this.
    uint256 public depositThreshold;

    /// @notice `flushWithdrawals` (and `flushAll`) open once `pendingWithdrawals` reaches this.
    uint256 public withdrawThreshold;

    /// @notice phUSD paid to the `stakePending` keeper.
    uint256 public stakeReward;

    /// @notice Fixed phUSD fee paid to the `flushWithdrawals` keeper out of the owed phUSD being
    ///         burnt, capped at that amount (never minted).
    uint256 public withdrawFee;

    /// @notice phUSD paid to the `flushAll` keeper instead of the individual rewards.
    uint256 public flushAllReward;

    /// @notice phUSD a swapper pays for the vault's whole balance of `token`. 0 = not swappable.
    mapping(address token => uint256 phUSDPrice) public swapPrice;

    /// @notice Address authorised to pause (the global PauserV2). `address(0)` disables pausing.
    address public pauser;

    // ========================== ERRORS ==========================

    /// @notice A constructor or recipient address argument is zero.
    error StakedPhUSD__ZeroAddress();
    /// @notice Phlimbo's `phUSD()` / `rewardToken()` do not match the constructor arguments.
    error StakedPhUSD__PhlimboMismatch();
    /// @notice A payout recipient is the owner; no funds may ever be sent to the owner.
    error StakedPhUSD__RecipientIsOwner();
    /// @notice Caller is not the pauser.
    error StakedPhUSD__NotPauser();
    /// @notice Caller is neither the pauser nor the owner.
    error StakedPhUSD__NotPauserOrOwner();
    /// @notice A keeper gate is not met.
    /// @param queued The queued amount the gate measured.
    /// @param threshold The threshold it had to reach.
    error StakedPhUSD__BelowThreshold(uint256 queued, uint256 threshold);
    /// @notice The queue(s) a keeper call would flush are empty.
    error StakedPhUSD__NothingToFlush();
    /// @notice `swap` on a token with no configured price.
    /// @param token The token.
    error StakedPhUSD__NotSwappable(address token);
    /// @notice `swap` found no balance of the token to pay out, even after claiming.
    /// @param token The token.
    error StakedPhUSD__NothingToSwap(address token);
    /// @notice phUSD or sphUSD cannot be configured as a swap token or swept.
    /// @param token The token.
    error StakedPhUSD__ProtectedToken(address token);
    /// @notice `sweepToken` on a token with a non-zero `swapPrice` (it belongs to swappers).
    /// @param token The token.
    error StakedPhUSD__ConfiguredSwapToken(address token);
    /// @notice Minting phUSD failed (minter role not granted or revoked).
    /// @param recipient The intended recipient.
    /// @param amount The amount that could not be minted.
    error StakedPhUSD__MintFailed(address recipient, uint256 amount);
    /// @notice A keeper reward or fee exceeds `MAX_KEEPER_REWARD`.
    /// @param value The rejected value.
    error StakedPhUSD__RewardTooHigh(uint256 value);
    /// @notice `withdrawFee` would exceed `withdrawThreshold`.
    /// @param fee The fee.
    /// @param threshold The threshold.
    error StakedPhUSD__WithdrawFeeAboveThreshold(uint256 fee, uint256 threshold);
    /// @notice `stakeReward` would exceed `depositThreshold`.
    /// @param reward The reward.
    /// @param threshold The threshold.
    error StakedPhUSD__StakeRewardAboveThreshold(uint256 reward, uint256 threshold);
    /// @notice `flushAllReward` would exceed `stakeReward + withdrawFee`.
    /// @param flushAllReward The flushAll reward.
    /// @param cap `stakeReward + withdrawFee`.
    error StakedPhUSD__FlushAllRewardAboveCap(uint256 flushAllReward, uint256 cap);

    // ========================== EVENTS ==========================

    /// @notice Idle phUSD was cancelled (burnt) against owed phUSD before touching Phlimbo.
    /// @param amount The amount netted and burnt.
    event QueuesNetted(uint256 amount);
    /// @notice phUSD emitted by Phlimbo was captured into `pendingDeposits`.
    /// @param amount The emission captured.
    event EmissionsCaptured(uint256 amount);
    /// @notice `stakePending` ran.
    /// @param keeper The caller.
    /// @param rewardRecipient The reward recipient.
    /// @param staked phUSD staked into Phlimbo (0 when skipped below the minimum).
    /// @param reward phUSD paid to the recipient.
    event PendingStaked(address indexed keeper, address indexed rewardRecipient, uint256 staked, uint256 reward);
    /// @notice `flushWithdrawals` ran.
    /// @param keeper The caller.
    /// @param rewardRecipient The fee recipient.
    /// @param withdrawn phUSD requested from Phlimbo.
    /// @param burnt phUSD burnt.
    /// @param fee phUSD paid to the recipient.
    event WithdrawalsFlushed(
        address indexed keeper, address indexed rewardRecipient, uint256 withdrawn, uint256 burnt, uint256 fee
    );
    /// @notice `flushAll` ran.
    /// @param keeper The caller.
    /// @param rewardRecipient The reward recipient.
    /// @param staked phUSD staked into Phlimbo.
    /// @param withdrawn phUSD requested from Phlimbo.
    /// @param burnt phUSD burnt.
    /// @param reward phUSD paid to the recipient.
    event AllFlushed(
        address indexed keeper,
        address indexed rewardRecipient,
        uint256 staked,
        uint256 withdrawn,
        uint256 burnt,
        uint256 reward
    );
    /// @notice A reward token balance was swapped for phUSD.
    /// @param swapper The caller who paid phUSD.
    /// @param token The token paid out.
    /// @param recipient The receiver of the token.
    /// @param phUSDPaid phUSD paid in (joins `pendingDeposits`).
    /// @param payout Token amount paid out.
    event Swapped(
        address indexed swapper, address indexed token, address indexed recipient, uint256 phUSDPaid, uint256 payout
    );
    /// @notice A stray token was swept by the owner.
    /// @param token The token.
    /// @param to The receiver.
    /// @param amount The amount swept.
    event TokenSwept(address indexed token, address indexed to, uint256 amount);
    /// @notice `depositThreshold` changed.
    event DepositThresholdUpdated(uint256 oldValue, uint256 newValue);
    /// @notice `withdrawThreshold` changed.
    event WithdrawThresholdUpdated(uint256 oldValue, uint256 newValue);
    /// @notice `stakeReward` changed.
    event StakeRewardUpdated(uint256 oldValue, uint256 newValue);
    /// @notice `withdrawFee` changed.
    event WithdrawFeeUpdated(uint256 oldValue, uint256 newValue);
    /// @notice `flushAllReward` changed.
    event FlushAllRewardUpdated(uint256 oldValue, uint256 newValue);
    /// @notice `swapPrice[token]` changed.
    event SwapPriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);
    /// @notice The pauser changed.
    event PauserChanged(address indexed previousPauser, address indexed newPauser);

    // ========================== MODIFIERS ==========================

    /// @dev Rejects the zero address and the owner as a payout recipient.
    modifier validRecipient(address recipient) {
        _checkRecipient(recipient);
        _;
    }

    // ========================== CONSTRUCTOR ==========================

    /// @notice Deploy the vault. All keeper parameters start at 0 and are configured by the owner.
    /// @param phUSD_ The phUSD token (vault asset).
    /// @param phlimbo_ The PhlimboV3 instance to stake into.
    /// @param usdc_ USDC (must equal `phlimbo_.rewardToken()`).
    /// @param initialOwner The owner (OZ `Ownable` rejects zero).
    /// @param pauser_ The pauser (the global PauserV2).
    constructor(IPhUSD phUSD_, IPhlimboV3Minimal phlimbo_, IERC20 usdc_, address initialOwner, address pauser_)
        ERC20("Staked PhUSD", "sphUSD")
        ERC4626(IERC20(address(phUSD_)))
        Ownable(initialOwner)
    {
        if (
            address(phUSD_) == address(0) || address(phlimbo_) == address(0) || address(usdc_) == address(0)
                || pauser_ == address(0)
        ) revert StakedPhUSD__ZeroAddress();
        if (phlimbo_.phUSD() != address(phUSD_) || phlimbo_.rewardToken() != address(usdc_)) {
            revert StakedPhUSD__PhlimboMismatch();
        }
        phUSD = phUSD_;
        phlimbo = phlimbo_;
        usdc = usdc_;
        pauser = pauser_;
        emit PauserChanged(address(0), pauser_);
    }

    // ========================== ERC4626 ==========================

    /// @notice Assets backing the shares: staked position plus idle phUSD, minus phUSD owed to nobody.
    /// @return The vault's assets in phUSD.
    function totalAssets() public view override returns (uint256) {
        return stakedInPhlimbo + pendingDeposits - pendingWithdrawals;
    }

    /// @notice 0 while paused; otherwise unlimited.
    function maxDeposit(address receiver) public view override returns (uint256) {
        return paused() ? 0 : super.maxDeposit(receiver);
    }

    /// @notice 0 while paused; otherwise unlimited.
    function maxMint(address receiver) public view override returns (uint256) {
        return paused() ? 0 : super.maxMint(receiver);
    }

    /// @notice 0 while paused; otherwise the standard value.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        return paused() ? 0 : super.maxWithdraw(owner_);
    }

    /// @notice 0 while paused; otherwise the standard value.
    function maxRedeem(address owner_) public view override returns (uint256) {
        return paused() ? 0 : super.maxRedeem(owner_);
    }

    /// @dev Pull phUSD, mint shares (OZ), and queue the phUSD for staking.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
        validRecipient(receiver)
    {
        super._deposit(caller, receiver, assets, shares);
        pendingDeposits += assets;
    }

    /// @dev Burn shares, then pay from idle phUSD first and mint the remainder (queued for burning).
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
        validRecipient(receiver)
    {
        if (caller != owner_) {
            _spendAllowance(owner_, caller, shares);
        }
        _burn(owner_, shares);

        uint256 idle = pendingDeposits;
        uint256 fromIdle = assets < idle ? assets : idle;
        uint256 remainder = assets - fromIdle;

        pendingDeposits = idle - fromIdle;
        pendingWithdrawals += remainder;

        if (fromIdle > 0) {
            IERC20(address(phUSD)).safeTransfer(receiver, fromIdle);
        }
        if (remainder > 0) {
            _mintPhUSD(receiver, remainder);
        }

        emit Withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev OZ virtual-shares offset (inflation-attack defence).
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    // ========================== KEEPERS ==========================

    /// @notice Stake the deposit queue into Phlimbo for a phUSD reward. Permissionless.
    /// @dev Gate: `pendingDeposits >= depositThreshold` (and non-zero). Nets against
    ///      `pendingWithdrawals` first (burning the overlap), then stakes the rest unless it is
    ///      below Phlimbo's minimum. Reverts while Phlimbo is paused if a stake is needed.
    /// @param rewardRecipient Receiver of `stakeReward`.
    /// @return staked phUSD staked into Phlimbo.
    function stakePending(address rewardRecipient)
        external
        nonReentrant
        whenNotPaused
        validRecipient(rewardRecipient)
        returns (uint256 staked)
    {
        uint256 queued = pendingDeposits;
        if (queued == 0) revert StakedPhUSD__NothingToFlush();
        if (queued < depositThreshold) revert StakedPhUSD__BelowThreshold(queued, depositThreshold);

        uint256 netted = _netQueues();
        staked = _stakeIdle();

        uint256 reward = stakeReward;
        _settle(rewardRecipient, reward, netted, true);

        emit PendingStaked(msg.sender, rewardRecipient, staked, reward);
    }

    /// @notice Unstake and burn the withdrawal queue for a capped phUSD fee. Permissionless.
    /// @dev Gate: `pendingWithdrawals >= withdrawThreshold` (and non-zero). Nets against
    ///      `pendingDeposits` first, withdraws the rest from Phlimbo, pays
    ///      `min(withdrawFee, owed phUSD burnt this call)` to the recipient and burns the rest.
    ///      Dust-rule excess from Phlimbo joins `pendingDeposits`.
    /// @param rewardRecipient Receiver of the fee.
    /// @return burnt phUSD burnt.
    function flushWithdrawals(address rewardRecipient)
        external
        nonReentrant
        whenNotPaused
        validRecipient(rewardRecipient)
        returns (uint256 burnt)
    {
        uint256 queued = pendingWithdrawals;
        if (queued == 0) revert StakedPhUSD__NothingToFlush();
        if (queued < withdrawThreshold) revert StakedPhUSD__BelowThreshold(queued, withdrawThreshold);

        uint256 netted = _netQueues();
        uint256 withdrawn = _withdrawOwed();

        uint256 owed = netted + withdrawn;
        uint256 fee = withdrawFee < owed ? withdrawFee : owed;
        burnt = _settle(rewardRecipient, fee, owed, false);

        emit WithdrawalsFlushed(msg.sender, rewardRecipient, withdrawn, burnt, fee);
    }

    /// @notice Flush both queues for a single phUSD reward. Permissionless.
    /// @dev The aggregate of the two individual flushes, never a way around their gates: it opens
    ///      only when `pendingDeposits + pendingWithdrawals >= depositThreshold + withdrawThreshold`.
    ///      Pays `flushAllReward` (capped at `stakeReward + withdrawFee` by the setters), first out of
    ///      owed phUSD being burnt and the shortfall minted.
    /// @param rewardRecipient Receiver of `flushAllReward`.
    /// @return staked phUSD staked into Phlimbo.
    /// @return withdrawn phUSD withdrawn from Phlimbo.
    function flushAll(address rewardRecipient)
        external
        nonReentrant
        whenNotPaused
        validRecipient(rewardRecipient)
        returns (uint256 staked, uint256 withdrawn)
    {
        uint256 queued = pendingDeposits + pendingWithdrawals;
        uint256 gate = depositThreshold + withdrawThreshold;
        if (queued == 0) revert StakedPhUSD__NothingToFlush();
        if (queued < gate) revert StakedPhUSD__BelowThreshold(queued, gate);

        uint256 netted = _netQueues();
        // After netting at most one queue is non-zero.
        withdrawn = _withdrawOwed();
        staked = _stakeIdle();

        uint256 reward = flushAllReward;
        uint256 burnt = _settle(rewardRecipient, reward, netted + withdrawn, true);

        emit AllFlushed(msg.sender, rewardRecipient, staked, withdrawn, burnt, reward);
    }

    /// @notice Pay `swapPrice[token]` phUSD for the vault's whole balance of `token`. Permissionless.
    /// @dev Claims Phlimbo first (skipped while Phlimbo is paused or the vault has no position) so the
    ///      payout includes freshly claimed rewards; then reads `balanceOf`. A claim may also drop
    ///      other reward tokens; they stay for their own `swap`. The phUSD paid joins
    ///      `pendingDeposits`, raising the share price.
    /// @param token The reward token to buy.
    /// @param recipient Receiver of the token balance.
    /// @return payout Amount of `token` paid out.
    function swap(IERC20 token, address recipient)
        external
        nonReentrant
        whenNotPaused
        validRecipient(recipient)
        returns (uint256 payout)
    {
        uint256 price = swapPrice[address(token)];
        if (price == 0) revert StakedPhUSD__NotSwappable(address(token));

        IERC20(address(phUSD)).safeTransferFrom(msg.sender, address(this), price);

        if (stakedInPhlimbo > 0 && !phlimbo.paused()) {
            uint256 before = phUSD.balanceOf(address(this));
            phlimbo.claim(address(this));
            _captureEmission(phUSD.balanceOf(address(this)) - before);
        }

        payout = token.balanceOf(address(this));
        if (payout == 0) revert StakedPhUSD__NothingToSwap(address(token));
        token.safeTransfer(recipient, payout);

        pendingDeposits += price;

        emit Swapped(msg.sender, address(token), recipient, price, payout);
    }

    // ========================== OWNER CONFIGURATION ==========================

    /// @notice Set the deposit-queue threshold. Must stay >= `stakeReward`.
    /// @param newValue The new threshold (phUSD, 18 dp).
    function setDepositThreshold(uint256 newValue) external onlyOwner {
        if (stakeReward > newValue) revert StakedPhUSD__StakeRewardAboveThreshold(stakeReward, newValue);
        emit DepositThresholdUpdated(depositThreshold, newValue);
        depositThreshold = newValue;
    }

    /// @notice Set the withdrawal-queue threshold. Must stay >= `withdrawFee`.
    /// @param newValue The new threshold (phUSD, 18 dp).
    function setWithdrawThreshold(uint256 newValue) external onlyOwner {
        if (withdrawFee > newValue) revert StakedPhUSD__WithdrawFeeAboveThreshold(withdrawFee, newValue);
        emit WithdrawThresholdUpdated(withdrawThreshold, newValue);
        withdrawThreshold = newValue;
    }

    /// @notice Set the `stakePending` reward. Capped at `MAX_KEEPER_REWARD` and `depositThreshold`,
    ///         and must keep `flushAllReward <= stakeReward + withdrawFee`.
    /// @param newValue The new reward (phUSD, 18 dp).
    function setStakeReward(uint256 newValue) external onlyOwner {
        if (newValue > MAX_KEEPER_REWARD) revert StakedPhUSD__RewardTooHigh(newValue);
        if (newValue > depositThreshold) revert StakedPhUSD__StakeRewardAboveThreshold(newValue, depositThreshold);
        _checkFlushAllCap(flushAllReward, newValue, withdrawFee);
        emit StakeRewardUpdated(stakeReward, newValue);
        stakeReward = newValue;
    }

    /// @notice Set the `flushWithdrawals` fee. Capped at `MAX_KEEPER_REWARD` and `withdrawThreshold`,
    ///         and must keep `flushAllReward <= stakeReward + withdrawFee`.
    /// @param newValue The new fee (phUSD, 18 dp).
    function setWithdrawFee(uint256 newValue) external onlyOwner {
        if (newValue > MAX_KEEPER_REWARD) revert StakedPhUSD__RewardTooHigh(newValue);
        if (newValue > withdrawThreshold) revert StakedPhUSD__WithdrawFeeAboveThreshold(newValue, withdrawThreshold);
        _checkFlushAllCap(flushAllReward, stakeReward, newValue);
        emit WithdrawFeeUpdated(withdrawFee, newValue);
        withdrawFee = newValue;
    }

    /// @notice Set the `flushAll` reward. Capped at `MAX_KEEPER_REWARD` and `stakeReward + withdrawFee`.
    /// @param newValue The new reward (phUSD, 18 dp).
    function setFlushAllReward(uint256 newValue) external onlyOwner {
        if (newValue > MAX_KEEPER_REWARD) revert StakedPhUSD__RewardTooHigh(newValue);
        _checkFlushAllCap(newValue, stakeReward, withdrawFee);
        emit FlushAllRewardUpdated(flushAllReward, newValue);
        flushAllReward = newValue;
    }

    /// @notice Set the phUSD price a swapper pays for the vault's whole `token` balance. 0 disables.
    /// @dev phUSD and sphUSD can never be configured. Configure only liquid tokens.
    /// @param token The reward token.
    /// @param phUSDPrice The phUSD price (18 dp); 0 disables swapping.
    function setSwapPrice(address token, uint256 phUSDPrice) external onlyOwner {
        if (token == address(0)) revert StakedPhUSD__ZeroAddress();
        if (token == address(phUSD) || token == address(this)) revert StakedPhUSD__ProtectedToken(token);
        emit SwapPriceUpdated(token, swapPrice[token], phUSDPrice);
        swapPrice[token] = phUSDPrice;
    }

    /// @notice Owner fallback for genuinely stray tokens: send the whole balance of `token` to `to`.
    /// @dev Reverts for phUSD, sphUSD, any token with a non-zero `swapPrice`, `to == owner()` and
    ///      `to == address(0)`.
    /// @param token The stray token.
    /// @param to The receiver (never the owner).
    /// @return amount The amount swept.
    function sweepToken(IERC20 token, address to)
        external
        onlyOwner
        nonReentrant
        validRecipient(to)
        returns (uint256 amount)
    {
        address t = address(token);
        if (t == address(phUSD) || t == address(this)) revert StakedPhUSD__ProtectedToken(t);
        if (swapPrice[t] != 0) revert StakedPhUSD__ConfiguredSwapToken(t);
        amount = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        emit TokenSwept(t, to, amount);
    }

    // ========================== PAUSE ==========================

    /// @notice Set the pauser. `address(0)` disables pausing by the pauser (owner can still unpause).
    /// @param newPauser The new pauser.
    function setPauser(address newPauser) external onlyOwner {
        emit PauserChanged(pauser, newPauser);
        pauser = newPauser;
    }

    /// @notice Pause deposits, withdrawals and keepers. Pauser only. Idempotent: never reverts for
    ///         the pauser when already paused (PauserV2 calls it without try/catch).
    /// @dev Share (ERC20) transfers are never paused.
    function pause() external override {
        if (msg.sender != pauser) revert StakedPhUSD__NotPauser();
        if (!paused()) _pause();
    }

    /// @notice Unpause. Owner or pauser. Idempotent.
    function unpause() external override {
        if (msg.sender != pauser && msg.sender != owner()) revert StakedPhUSD__NotPauserOrOwner();
        if (paused()) _unpause();
    }

    // ========================== INTERNAL ==========================

    /// @dev Cancel idle phUSD against owed phUSD (burning it) so nothing is staked only to be burnt.
    /// @return netted The amount cancelled and burnt.
    function _netQueues() internal returns (uint256 netted) {
        uint256 pd = pendingDeposits;
        uint256 pw = pendingWithdrawals;
        netted = pd < pw ? pd : pw;
        if (netted > 0) {
            pendingDeposits = pd - netted;
            pendingWithdrawals = pw - netted;
            emit QueuesNetted(netted);
        }
    }

    /// @dev Stake all of `pendingDeposits` unless below Phlimbo's minimum.
    /// @return staked The amount staked (0 when skipped).
    function _stakeIdle() internal returns (uint256 staked) {
        staked = pendingDeposits;
        if (staked < PHLIMBO_MINIMUM_STAKE) return 0;
        pendingDeposits = 0;

        IERC20(address(phUSD)).forceApprove(address(phlimbo), staked);
        uint256 before = phUSD.balanceOf(address(this));
        phlimbo.stake(staked, address(this));
        // after = before - staked + emission
        _captureEmission(phUSD.balanceOf(address(this)) + staked - before);
        _reconcileStaked();
    }

    /// @dev Withdraw all of `pendingWithdrawals` from Phlimbo. Dust-rule excess joins `pendingDeposits`.
    /// @return withdrawn The amount requested (and owed).
    function _withdrawOwed() internal returns (uint256 withdrawn) {
        withdrawn = pendingWithdrawals;
        if (withdrawn == 0) return 0;
        pendingWithdrawals = 0;

        uint256 stakedBefore = _phlimboPosition();
        uint256 before = phUSD.balanceOf(address(this));
        phlimbo.withdraw(withdrawn, address(this));
        uint256 received = phUSD.balanceOf(address(this)) - before;
        _reconcileStaked();

        uint256 principal = stakedBefore - stakedInPhlimbo;
        _captureEmission(received - principal);
        if (principal > withdrawn) {
            // Dust rule: Phlimbo withdrew the whole position. The excess is vault assets.
            pendingDeposits += principal - withdrawn;
        }
    }

    /// @dev Pay `reward` to `recipient` out of `burnable` owed phUSD held by the vault, burn the rest
    ///      of `burnable`, and (when `mintShortfall`) mint any reward beyond `burnable`.
    /// @return burnt The amount burnt.
    function _settle(address recipient, uint256 reward, uint256 burnable, bool mintShortfall)
        internal
        returns (uint256 burnt)
    {
        uint256 fromOwed = reward < burnable ? reward : burnable;
        burnt = burnable - fromOwed;
        if (burnt > 0) {
            IERC20(address(phUSD)).forceApprove(address(this), burnt);
            phUSD.burn(address(this), burnt);
        }
        if (fromOwed > 0) {
            IERC20(address(phUSD)).safeTransfer(recipient, fromOwed);
        }
        if (mintShortfall && reward > fromOwed) {
            _mintPhUSD(recipient, reward - fromOwed);
        }
    }

    /// @dev Mint phUSD, reverting with a clear error if the vault lacks the minter role.
    function _mintPhUSD(address to, uint256 amount) internal {
        try phUSD.mint(to, amount) {}
        catch {
            revert StakedPhUSD__MintFailed(to, amount);
        }
    }

    /// @dev Add Phlimbo phUSD emissions (measured by balance delta) to `pendingDeposits`.
    function _captureEmission(uint256 amount) internal {
        if (amount > 0) {
            pendingDeposits += amount;
            emit EmissionsCaptured(amount);
        }
    }

    /// @dev Re-read the vault's Phlimbo position (absorbs the dust rule).
    function _reconcileStaked() internal {
        stakedInPhlimbo = _phlimboPosition();
    }

    /// @dev The vault's Phlimbo staked amount.
    function _phlimboPosition() internal view returns (uint256 amount) {
        (amount,,,) = phlimbo.userInfo(address(this));
    }

    /// @dev Reject zero and owner recipients.
    function _checkRecipient(address recipient) internal view {
        if (recipient == address(0)) revert StakedPhUSD__ZeroAddress();
        if (recipient == owner()) revert StakedPhUSD__RecipientIsOwner();
    }

    /// @dev Enforce `flushAllReward <= stakeReward + withdrawFee`.
    function _checkFlushAllCap(uint256 flushAllReward_, uint256 stakeReward_, uint256 withdrawFee_) internal pure {
        uint256 cap = stakeReward_ + withdrawFee_;
        if (flushAllReward_ > cap) revert StakedPhUSD__FlushAllRewardAboveCap(flushAllReward_, cap);
    }
}
