// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {FundShareToken} from "../src/FundShareToken.sol";
import {FundVault} from "../src/FundVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @title Deploy
/// @notice Deploys the fractional fund prototype and wires the contracts
///         together: Registry -> Token -> Vault.
///
/// @dev TARGET: Base Sepolia testnet (chain ID 84532) ONLY. Never point this
///      at a mainnet with real keys. The contracts are unaudited prototypes.
///
///      Environment variables:
///        DEPLOYER_KEY        Private key of the deployer (TESTNET key only).
///                            The deployer initially holds every admin role —
///                            reassign them to real operators after deploy.
///        BASE_SEPOLIA_RPC_URL RPC endpoint for Base Sepolia.
///        STABLECOIN_ADDRESS   (optional) Existing stablecoin to use. If unset,
///                            a MockUSDC is deployed for demo purposes.
///        INITIAL_NAV          (optional) Initial NAV per share, in stablecoin
///                            base units. Defaults to $25.00 assuming a
///                            6-decimal stablecoin (25_000_000).
///
///      Example:
///        source .env
///        forge script script/Deploy.s.sol:Deploy \
///          --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        address stablecoinAddr = vm.envOr("STABLECOIN_ADDRESS", address(0));
        uint256 initialNav = vm.envOr("INITIAL_NAV", uint256(25_000_000));

        vm.startBroadcast(deployerKey);

        // 1. Stablecoin: use the provided one, or deploy a mock for demo.
        IERC20 stablecoin;
        if (stablecoinAddr == address(0)) {
            MockUSDC mock = new MockUSDC();
            stablecoin = IERC20(address(mock));
            console.log("MockUSDC deployed at:", address(mock));
        } else {
            stablecoin = IERC20(stablecoinAddr);
            console.log("Using existing stablecoin at:", stablecoinAddr);
        }

        // 2. IdentityRegistry: deployer is admin + compliance (reassign later).
        IdentityRegistry registry = new IdentityRegistry(deployer, deployer);
        console.log("IdentityRegistry deployed at:", address(registry));

        // 3. FundShareToken: deployer is admin + transfer agent (reassign later).
        FundShareToken token = new FundShareToken(deployer, deployer, registry);
        console.log("FundShareToken deployed at:", address(token));

        // 4. FundVault: deployer is admin + NAV updater (reassign later).
        FundVault vault = new FundVault(deployer, deployer, stablecoin, token, registry, initialNav);
        console.log("FundVault deployed at:", address(vault));
        console.log("Initial NAV per share:", initialNav);

        // 5. Wire roles: the vault must be able to mint/burn shares.
        token.grantRole(token.TRANSFER_AGENT_ROLE(), address(vault));
        console.log("Granted TRANSFER_AGENT_ROLE to vault");

        vm.stopBroadcast();

        console.log("---");
        console.log("NEXT STEPS (do these before any demo):");
        console.log("1. Grant COMPLIANCE_ROLE to the real compliance operator.");
        console.log("2. Grant TRANSFER_AGENT_ROLE to the transfer agent multisig,");
        console.log("   then revoke it from the deployer.");
        console.log("3. Grant NAV_UPDATER_ROLE to the NAV feed operator.");
        console.log("4. Transfer DEFAULT_ADMIN_ROLE to a multisig / timelock.");
    }
}
