// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {FundShareToken} from "../src/FundShareToken.sol";
import {FundVault} from "../src/FundVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Test suite for the fractional mutual fund prototype.
/// @dev Conventions: `this` test contract holds every admin role. Alice and
///      Bob are investors; Carol is never verified. USDC has 6 decimals, so
///      100 USDC == 100e6 base units. NAV is stored in stablecoin BASE UNITS
///      per share, so a $25.00 NAV == 25_000_000.
contract FractionalFundTest is Test {
    IdentityRegistry registry;
    FundShareToken token;
    FundVault vault;
    MockUSDC usdc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol"); // never verified

    uint256 constant NAV_25 = 25_000_000; // $25.00 in USDC base units
    uint256 constant NAV_50 = 50_000_000; // $50.00 in USDC base units

    function setUp() public {
        registry = new IdentityRegistry(address(this), address(this));
        token = new FundShareToken(address(this), address(this), registry);
        usdc = new MockUSDC();
        vault = new FundVault(address(this), address(this), usdc, token, registry, NAV_25);

        // The vault mints/burns shares on subscribe/redeem.
        token.grantRole(token.TRANSFER_AGENT_ROLE(), address(vault));

        // Verify Alice and Bob with no expiry; fund them with mock USDC.
        registry.addInvestor(alice, 0);
        registry.addInvestor(bob, 0);
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    // -------------------------------------------------------------------------
    // IdentityRegistry
    // -------------------------------------------------------------------------

    function test_registry_add_and_isVerified() public view {
        assertTrue(registry.isVerified(alice));
        assertFalse(registry.isVerified(carol));
    }

    function test_registry_remove_revokes_verification() public {
        registry.removeInvestor(alice);
        assertFalse(registry.isVerified(alice));
    }

    function test_registry_expiry_lapses() public {
        registry.addInvestor(carol, uint64(block.timestamp + 1 days));
        assertTrue(registry.isVerified(carol));
        vm.warp(block.timestamp + 2 days);
        assertFalse(registry.isVerified(carol));
    }

    function test_registry_flag_blocks_verification() public {
        registry.setFlag(alice, true);
        assertFalse(registry.isVerified(alice));
        registry.setFlag(alice, false);
        assertTrue(registry.isVerified(alice));
    }

    function test_registry_nonCompliance_cannot_add() public {
        vm.prank(carol);
        vm.expectRevert();
        registry.addInvestor(carol, 0);
    }

    function test_registry_rejects_zero_address() public {
        vm.expectRevert(IdentityRegistry.ZeroAddress.selector);
        registry.addInvestor(address(0), 0);
    }

    // -------------------------------------------------------------------------
    // FundShareToken gating
    // -------------------------------------------------------------------------

    function test_token_mint_to_unverified_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.NotVerified.selector, carol));
        token.mint(carol, 1e18);
    }

    function test_token_transfer_to_unverified_reverts() public {
        token.mint(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.NotVerified.selector, carol));
        token.transfer(carol, 1e18);
    }

    function test_token_transfer_from_unverified_reverts() public {
        // Carol holds shares only if she was verified at mint time...
        registry.addInvestor(carol, 0);
        token.mint(carol, 10e18);
        registry.removeInvestor(carol); // ...then loses verification
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.NotVerified.selector, carol));
        token.transfer(alice, 1e18);
    }

    function test_token_verified_transfer_works() public {
        token.mint(alice, 10e18);
        vm.prank(alice);
        token.transfer(bob, 4e18);
        assertEq(token.balanceOf(bob), 4e18);
        assertEq(token.balanceOf(alice), 6e18);
    }

    function test_token_freeze_blocks_transfer() public {
        token.mint(alice, 10e18);
        token.setFrozen(alice, true);
        assertTrue(token.isFrozen(alice));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.AccountIsFrozen.selector, alice));
        token.transfer(bob, 1e18);

        // Receiving while frozen also blocked.
        token.setFrozen(alice, false);
        token.setFrozen(bob, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.AccountIsFrozen.selector, bob));
        token.transfer(bob, 1e18);

        // Unfreeze restores normal operation.
        token.setFrozen(bob, false);
        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_token_forceTransfer_bypasses_freeze_but_requires_verified() public {
        token.mint(alice, 10e18);
        token.setFrozen(alice, true);

        // Forced transfer works despite the freeze, with an on-chain reason.
        token.forceTransfer(alice, bob, 3e18, "court order 2026-1234");
        assertEq(token.balanceOf(bob), 3e18);
        assertEq(token.balanceOf(alice), 7e18);

        // ...but not to an unverified account.
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.NotVerified.selector, carol));
        token.forceTransfer(alice, carol, 1e18, "should fail");
    }

    function test_token_pause_blocks_all_movements() public {
        token.mint(alice, 10e18);
        token.pause();
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1e18);
        token.unpause();
        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_token_nonAgent_cannot_mint() public {
        vm.prank(carol);
        vm.expectRevert();
        token.mint(carol, 1e18);
    }

    function test_token_nonAdmin_cannot_pause() public {
        vm.prank(carol);
        vm.expectRevert();
        token.pause();
    }

    // -------------------------------------------------------------------------
    // FundVault subscribe / redeem
    // -------------------------------------------------------------------------

    function _subscribeAs(address investor, uint256 amount) internal returns (uint256) {
        vm.startPrank(investor);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.subscribe(amount);
        vm.stopPrank();
        return shares;
    }

    function test_vault_subscribe_mints_correct_shares() public {
        // 100 USDC at $25 NAV -> 4 shares (4e18).
        uint256 shares = _subscribeAs(alice, 100e6);
        assertEq(shares, 4e18);
        assertEq(token.balanceOf(alice), 4e18);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
    }

    function test_vault_subscribe_fractional() public {
        // 10 USDC at $25 NAV -> 0.4 shares.
        uint256 shares = _subscribeAs(alice, 10e6);
        assertEq(shares, 0.4e18);
    }

    function test_vault_unverified_cannot_subscribe() public {
        vm.startPrank(carol);
        usdc.mint(carol, 100e6);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotVerified.selector, carol));
        vault.subscribe(100e6);
        vm.stopPrank();
    }

    function test_vault_redeem_pays_correct_amount() public {
        _subscribeAs(alice, 100e6); // 4 shares
        uint256 before = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 payout = vault.redeem(4e18);

        assertEq(payout, 100e6);
        assertEq(usdc.balanceOf(alice), before + 100e6);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_vault_partial_redeem() public {
        _subscribeAs(alice, 100e6); // 4 shares
        vm.prank(alice);
        uint256 payout = vault.redeem(1e18); // 1 share -> $25
        assertEq(payout, 25e6);
        assertEq(token.balanceOf(alice), 3e18);
    }

    function test_vault_unverified_cannot_redeem() public {
        _subscribeAs(alice, 100e6);
        registry.removeInvestor(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotVerified.selector, alice));
        vault.redeem(1e18);
    }

    function test_vault_nav_update_changes_pricing() public {
        _subscribeAs(alice, 100e6); // 4 shares @ $25

        vault.setNavPerShare(NAV_50);
        assertEq(vault.navPerShare(), NAV_50);

        // New subscription at $50: 100 USDC -> 2 shares.
        uint256 shares = _subscribeAs(bob, 100e6);
        assertEq(shares, 2e18);

        // Old shares redeem at the NEW nav: 4 shares -> $200.
        vm.prank(alice);
        uint256 payout = vault.redeem(4e18);
        assertEq(payout, 200e6);
    }

    function test_vault_nav_zero_reverts() public {
        vm.expectRevert(FundVault.NavMustBePositive.selector);
        vault.setNavPerShare(0);
    }

    function test_vault_nonUpdater_cannot_set_nav() public {
        vm.prank(carol);
        vm.expectRevert();
        vault.setNavPerShare(NAV_50);
    }

    function test_vault_redeem_beyond_reserve_reverts() public {
        _subscribeAs(alice, 100e6); // 4 shares, reserve = 100 USDC
        vault.setNavPerShare(NAV_50); // 4 shares now worth 200 USDC > reserve
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(4e18);
    }

    function test_vault_subscribe_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(FundVault.ZeroAmount.selector);
        vault.subscribe(0);
    }

    function test_vault_withdrawReserve_admin_only() public {
        _subscribeAs(alice, 100e6);
        address treasury = makeAddr("treasury");

        vault.withdrawReserve(treasury, 40e6);
        assertEq(usdc.balanceOf(treasury), 40e6);
        assertEq(usdc.balanceOf(address(vault)), 60e6);

        vm.prank(carol);
        vm.expectRevert();
        vault.withdrawReserve(treasury, 1e6);
    }

    function test_vault_constructor_rejects_zero_nav() public {
        vm.expectRevert(FundVault.NavMustBePositive.selector);
        new FundVault(address(this), address(this), usdc, token, registry, 0);
    }

    // -------------------------------------------------------------------------
    // End-to-end
    // -------------------------------------------------------------------------

    function test_end_to_end_subscribe_nav_up_redeem() public {
        // Alice subscribes 1,000 USDC @ $25 -> 40 shares.
        uint256 shares = _subscribeAs(alice, 1_000e6);
        assertEq(shares, 40e18);

        // Fund performs: NAV rises to $50.
        vault.setNavPerShare(NAV_50);

        // Alice redeems half: 20 shares -> $1,000.
        // (Vault needs the reserve topped up to cover NAV appreciation,
        //  modeling off-chain asset gains flowing back.)
        usdc.mint(address(vault), 1_000e6);
        vm.prank(alice);
        uint256 payout = vault.redeem(20e18);
        assertEq(payout, 1_000e6);
        assertEq(token.balanceOf(alice), 20e18);
    }
}
