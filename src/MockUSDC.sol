// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice 6-decimal mock stablecoin for local tests and Base Sepolia demos ONLY.
/// @dev Never use on mainnet. Anyone can mint — it has no value and no backing.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "mUSDC") {}

    /// @notice 6 decimals, like real USDC.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint mock tokens to any address. Demo only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
