// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title IdentityRegistry
/// @notice Allowlist of KYC-verified investors for the fractional fund system.
/// @dev PROTOTYPE — unaudited. In production this registry must be fed by a
///      licensed KYC/AML provider and governed by the transfer agent, not by a
///      single EOA. Verification records carry an expiry so stale KYC cannot
///      linger; a flagged investor fails `isVerified` even before expiry.
contract IdentityRegistry is AccessControl {
    /// @notice Role allowed to add, remove, flag, and unflag investors.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @notice Per-investor compliance record.
    struct Investor {
        bool verified; // set true by compliance after KYC passes
        uint64 expiresAt; // unix timestamp after which verification lapses; 0 = never expires
        bool flagged; // compliance hold (e.g. sanctions hit); blocks isVerified
    }

    /// @notice investor address => compliance record.
    mapping(address => Investor) private _investors;

    /// @notice Emitted when an investor is added or re-verified.
    event InvestorAdded(address indexed investor, uint64 expiresAt);
    /// @notice Emitted when an investor's record is removed entirely.
    event InvestorRemoved(address indexed investor);
    /// @notice Emitted when an investor is flagged (true) or unflagged (false).
    event InvestorFlagged(address indexed investor, bool flagged);

    /// @notice Thrown when an address fails the verification check.
    error NotVerified(address account);
    /// @notice Thrown when a zero address is passed where an investor is expected.
    error ZeroAddress();

    /// @param admin Address receiving DEFAULT_ADMIN_ROLE (can grant/revoke roles).
    /// @param compliance Address receiving COMPLIANCE_ROLE (manages the allowlist).
    ///        Pass the same address for both in a demo; separate them in production.
    constructor(address admin, address compliance) {
        if (admin == address(0) || compliance == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, compliance);
    }

    /// @notice Add or re-verify an investor.
    /// @param investor The investor's wallet address.
    /// @param expiresAt Unix timestamp when verification lapses (0 = no expiry).
    function addInvestor(address investor, uint64 expiresAt) external onlyRole(COMPLIANCE_ROLE) {
        if (investor == address(0)) revert ZeroAddress();
        _investors[investor] = Investor({verified: true, expiresAt: expiresAt, flagged: false});
        emit InvestorAdded(investor, expiresAt);
    }

    /// @notice Remove an investor's record entirely.
    /// @dev Does not freeze token balances — freezing is the token's job.
    function removeInvestor(address investor) external onlyRole(COMPLIANCE_ROLE) {
        delete _investors[investor];
        emit InvestorRemoved(investor);
    }

    /// @notice Place or lift a compliance flag on an investor.
    /// @dev A flagged investor fails `isVerified` immediately.
    function setFlag(address investor, bool flagged) external onlyRole(COMPLIANCE_ROLE) {
        _investors[investor].flagged = flagged;
        emit InvestorFlagged(investor, flagged);
    }

    /// @notice Returns true only if the investor is verified, unflagged, and unexpired.
    function isVerified(address investor) public view returns (bool) {
        Investor memory record = _investors[investor];
        if (!record.verified || record.flagged) return false;
        if (record.expiresAt != 0 && block.timestamp > record.expiresAt) return false;
        return true;
    }

    /// @notice Read an investor's full compliance record.
    function getInvestor(address investor) external view returns (Investor memory) {
        return _investors[investor];
    }
}
