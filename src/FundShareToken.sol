// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";

import {IdentityRegistry} from "./IdentityRegistry.sol";

/// @title FundShareToken
/// @notice ERC20 representing fractional shares of a mutual fund. Placeholder
///         name/symbol — replace with the real fund's legal name before any
///         production use.
/// @dev PROTOTYPE — unaudited. Every balance movement is gated by the
///      IdentityRegistry: both the sender and the receiver must be verified.
///      For mints the sender is the zero address, so only the receiver is
///      checked; for burns only the sender is checked. This is the only sane
///      reading of "gate mints and burns" and is documented here deliberately.
///
///      The TRANSFER_AGENT_ROLE models the legal transfer agent's powers:
///      freezing accounts, forced transfers for corporate/legal actions, and
///      mint/burn for subscriptions and redemptions. In production these
///      powers belong to a regulated transfer agent (ideally a multisig),
///      never a single EOA.
contract FundShareToken is ERC20, ERC20Pausable, AccessControl {
    /// @notice Regulatory powers: freeze, forceTransfer, mint, burn.
    bytes32 public constant TRANSFER_AGENT_ROLE = keccak256("TRANSFER_AGENT_ROLE");

    /// @notice The allowlist every transfer is checked against. Immutable so the
    ///         compliance boundary cannot be swapped out from under holders.
    IdentityRegistry public immutable identityRegistry;

    /// @notice account => frozen. Frozen accounts cannot send or receive.
    mapping(address => bool) private _frozen;

    /// @notice Emitted when an account is frozen (true) or unfrozen (false).
    event AccountFrozen(address indexed account, bool frozen);
    /// @notice Emitted when the transfer agent forces a transfer.
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount, string reason);

    /// @notice Thrown when an account involved in a movement is not verified.
    error NotVerified(address account);
    /// @notice Thrown when an account involved in a movement is frozen.
    error AccountIsFrozen(address account);
    /// @notice Thrown when a zero address is passed where an account is expected.
    error ZeroAddress();

    /// @param admin Address receiving DEFAULT_ADMIN_ROLE (pausing + role admin).
    /// @param transferAgent Address receiving TRANSFER_AGENT_ROLE.
    /// @param registry The IdentityRegistry used for transfer gating.
    constructor(address admin, address transferAgent, IdentityRegistry registry) ERC20("Glenride Fractional Fund Share", "GFFS") {
        if (admin == address(0) || transferAgent == address(0)) revert ZeroAddress();
        if (address(registry) == address(0)) revert ZeroAddress();
        identityRegistry = registry;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TRANSFER_AGENT_ROLE, transferAgent);
    }

    // -------------------------------------------------------------------------
    // Transfer-agent powers
    // -------------------------------------------------------------------------

    /// @notice Freeze or unfreeze an account. Frozen accounts cannot send,
    ///         receive, mint to, or burn from via ordinary paths.
    function setFrozen(address account, bool frozen) external onlyRole(TRANSFER_AGENT_ROLE) {
        _frozen[account] = frozen;
        emit AccountFrozen(account, frozen);
    }

    /// @notice Returns true if the account is frozen.
    function isFrozen(address account) external view returns (bool) {
        return _frozen[account];
    }

    /// @notice Forced transfer for legal/regulatory actions (e.g. court order,
    ///         estate settlement, error correction). Bypasses the freeze and
    ///         needs no allowance. Both parties must still be verified, and a
    ///         global pause still blocks it.
    /// @param reason Human-readable reason, recorded on-chain for the audit trail.
    function forceTransfer(address from, address to, uint256 amount, string calldata reason)
        external
        onlyRole(TRANSFER_AGENT_ROLE)
    {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        _checkGates(from, to, false); // verification yes, freeze no
        // super._update resolves to ERC20Pausable._update: pause is still
        // enforced, while the freeze/verification gates above were explicit.
        super._update(from, to, amount);
        emit ForcedTransfer(from, to, amount, reason);
    }

    /// @notice Mint shares. Intended to be called by the FundVault on subscription.
    function mint(address to, uint256 amount) external onlyRole(TRANSFER_AGENT_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burn shares. Intended to be called by the FundVault on redemption.
    function burn(address from, uint256 amount) external onlyRole(TRANSFER_AGENT_ROLE) {
        _burn(from, amount);
    }

    // -------------------------------------------------------------------------
    // Pausing (admin)
    // -------------------------------------------------------------------------

    /// @notice Pause all token movements. Emergency brake for the admin.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause token movements.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Transfer gating
    // -------------------------------------------------------------------------

    /// @dev Every ordinary balance movement passes through here. Pausing is
    ///      enforced by ERC20Pausable (via super._update); verification and
    ///      freeze checks are enforced by _checkGates. Mint (from == 0) checks
    ///      only the receiver; burn (to == 0) checks only the sender.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        _checkGates(from, to, true);
        super._update(from, to, value);
    }

    /// @dev Shared gate logic. `checkFreeze` is false only for forceTransfer,
    ///      the one path allowed to move frozen funds (verification still applies).
    function _checkGates(address from, address to, bool checkFreeze) internal view {
        if (from != address(0)) {
            if (!_isVerified(from)) revert NotVerified(from);
            if (checkFreeze && _frozen[from]) revert AccountIsFrozen(from);
        }
        if (to != address(0)) {
            if (!_isVerified(to)) revert NotVerified(to);
            if (checkFreeze && _frozen[to]) revert AccountIsFrozen(to);
        }
    }

    /// @dev Single place where "verified" is defined for this token.
    function _isVerified(address account) internal view returns (bool) {
        return identityRegistry.isVerified(account);
    }
}
