// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FundShareToken} from "./FundShareToken.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";

/// @title FundVault
/// @notice Subscription/redemption engine for the fractional fund. Investors
///         deposit a stablecoin; the vault mints fractional shares at the
///         current NAV. Redemptions burn shares and return stablecoin at NAV.
/// @dev PROTOTYPE — unaudited, and deliberately simplified:
///      - NAV is pushed by a trusted NAV_UPDATER_ROLE. Production needs a
///        real NAV oracle or a fund-accountant feed, not a human with a key.
///      - Settlement is instant. Real mutual funds settle T+1 at a
///        forward-priced NAV; this prototype prices at the current NAV.
///      - The reserve sits in this contract. Production custody belongs with a
///        qualified custodian; `withdrawReserve` exists so the off-chain fund
///        manager can move cash to real-world assets.
///
///      NAV precision: `navPerShare` is denominated in stablecoin BASE UNITS
///      per share (e.g. a $25.00 NAV in 6-decimal USDC is stored as
///      25_000_000). Share math, with shares at 18 decimals:
///          sharesOut = depositAmount * 1e18 / navPerShare
///          payoutOut = shareAmount * navPerShare / 1e18
///      Integer division truncates, always in the fund's favor by dust.
///      Keeping NAV in base units (rather than scaled by 1e18) matches how
///      price feeds report and keeps the math to one scaling factor.
contract FundVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to publish new NAV values.
    bytes32 public constant NAV_UPDATER_ROLE = keccak256("NAV_UPDATER_ROLE");

    /// @notice Precision factor for share math (shares are 18-decimal).
    uint256 public constant PRECISION = 1e18;

    /// @notice Stablecoin investors deposit and redemptions pay out in.
    IERC20 public immutable stablecoin;
    /// @notice The fund share token this vault mints and burns.
    FundShareToken public immutable shareToken;
    /// @notice Allowlist consulted for subscribe/redeem.
    IdentityRegistry public immutable identityRegistry;

    /// @notice Current NAV per share, in stablecoin base units (must be > 0).
    uint256 public navPerShare;

    /// @notice Emitted on every subscription.
    event Subscribed(address indexed investor, uint256 depositAmount, uint256 sharesMinted, uint256 navPerShare);
    /// @notice Emitted on every redemption.
    event Redeemed(address indexed investor, uint256 sharesBurned, uint256 payoutAmount, uint256 navPerShare);
    /// @notice Emitted whenever the NAV changes, with old and new values.
    event NavUpdated(uint256 oldNav, uint256 newNav, address indexed updater);
    /// @notice Emitted when the admin moves reserve funds out of the vault.
    event ReserveWithdrawn(address indexed to, uint256 amount);

    /// @notice Thrown when an investor is not verified.
    error NotVerified(address account);
    /// @notice Thrown when NAV is set to zero.
    error NavMustBePositive();
    /// @notice Thrown on zero-amount subscribe/redeem (or dust too small to mint).
    error ZeroAmount();
    /// @notice Thrown when a zero address is passed where an account is expected.
    error ZeroAddress();
    /// @notice Thrown when a redemption would pay out more than the reserve holds.
    error InsufficientReserve(uint256 requested, uint256 available);

    /// @param admin Address receiving DEFAULT_ADMIN_ROLE.
    /// @param navUpdater Address receiving NAV_UPDATER_ROLE.
    /// @param stablecoin_ The stablecoin used for subscriptions/redemptions.
    /// @param shareToken_ The FundShareToken this vault mints/burns.
    /// @param registry The IdentityRegistry used for investor checks.
    /// @param initialNavPerShare Starting NAV per share (base units). Must be > 0.
    constructor(
        address admin,
        address navUpdater,
        IERC20 stablecoin_,
        FundShareToken shareToken_,
        IdentityRegistry registry,
        uint256 initialNavPerShare
    ) {
        if (admin == address(0) || navUpdater == address(0)) revert ZeroAddress();
        if (address(stablecoin_) == address(0) || address(shareToken_) == address(0)) revert ZeroAddress();
        if (address(registry) == address(0)) revert ZeroAddress();
        if (initialNavPerShare == 0) revert NavMustBePositive();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(NAV_UPDATER_ROLE, navUpdater);
        stablecoin = stablecoin_;
        shareToken = shareToken_;
        identityRegistry = registry;
        navPerShare = initialNavPerShare;
        emit NavUpdated(0, initialNavPerShare, msg.sender);
    }

    /// @notice Publish a new NAV per share.
    /// @dev Production: replace the human updater with an oracle/accountant feed.
    function setNavPerShare(uint256 newNav) external onlyRole(NAV_UPDATER_ROLE) {
        if (newNav == 0) revert NavMustBePositive();
        uint256 oldNav = navPerShare;
        navPerShare = newNav;
        emit NavUpdated(oldNav, newNav, msg.sender);
    }

    /// @notice Subscribe: deposit `amount` of stablecoin, receive fractional
    ///         shares at the current NAV. Caller must approve the vault first.
    /// @param amount Stablecoin base units to deposit (e.g. 100e6 = 100 USDC).
    /// @return sharesMinted Fractional shares minted (18 decimals).
    function subscribe(uint256 amount) external nonReentrant returns (uint256 sharesMinted) {
        if (!identityRegistry.isVerified(msg.sender)) revert NotVerified(msg.sender);
        if (amount == 0) revert ZeroAmount();

        sharesMinted = (amount * PRECISION) / navPerShare;
        if (sharesMinted == 0) revert ZeroAmount(); // deposit too small to mint even dust

        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        // The vault must hold TRANSFER_AGENT_ROLE on the share token.
        shareToken.mint(msg.sender, sharesMinted);

        emit Subscribed(msg.sender, amount, sharesMinted, navPerShare);
    }

    /// @notice Redeem: burn `shareAmount` of shares, receive stablecoin at the
    ///         current NAV.
    /// @param shareAmount Fractional shares to redeem (18 decimals).
    /// @return payoutAmount Stablecoin base units paid out.
    function redeem(uint256 shareAmount) external nonReentrant returns (uint256 payoutAmount) {
        if (!identityRegistry.isVerified(msg.sender)) revert NotVerified(msg.sender);
        if (shareAmount == 0) revert ZeroAmount();

        payoutAmount = (shareAmount * navPerShare) / PRECISION;
        if (payoutAmount == 0) revert ZeroAmount();

        uint256 reserve = stablecoin.balanceOf(address(this));
        if (payoutAmount > reserve) revert InsufficientReserve(payoutAmount, reserve);

        // Effects before interactions: burn first, then pay out.
        shareToken.burn(msg.sender, shareAmount);
        stablecoin.safeTransfer(msg.sender, payoutAmount);

        emit Redeemed(msg.sender, shareAmount, payoutAmount, navPerShare);
    }

    /// @notice Move reserve funds to the off-chain fund manager (e.g. to buy
    ///         the real-world assets the NAV tracks). Admin only.
    function withdrawReserve(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        stablecoin.safeTransfer(to, amount);
        emit ReserveWithdrawn(to, amount);
    }

    /// @notice Stablecoin decimals, for UIs converting between display and base units.
    function stablecoinDecimals() external view returns (uint8) {
        return IERC20Metadata(address(stablecoin)).decimals();
    }
}
