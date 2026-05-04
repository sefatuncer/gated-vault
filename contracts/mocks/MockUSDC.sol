// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  MockUSDC
/// @author Sefa Tunçer
/// @notice 6-decimal ERC-20 stand-in for USDC, used by the gated-vault test
///         suite and by local/testnet deployments where real USDC is not
///         available.
/// @dev    Test-only token. Not intended for production. The `mint` function
///         has no access control on purpose, so fuzz and integration tests can
///         create arbitrary balances. Real USDC has 6 decimals and is non
///         rebasing; this mock matches both properties so vault accounting
///         behaves the same against mock and real assets.
contract MockUSDC is ERC20 {
    /// @dev Decimal precision matching real USDC (Circle / Centre).
    uint8 private constant _DECIMALS = 6;

    constructor() ERC20("Mock USDC", "USDC") { }

    /// @notice Number of decimals used by this token.
    /// @return The decimal precision (6).
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    /// @notice Mints `amount` of MockUSDC to `to`.
    /// @dev    No access control by design; this contract is for testing only.
    ///         Production deployments must not use this token.
    /// @param  to     Recipient address.
    /// @param  amount Amount in 6-decimal units (1 USDC = 1e6).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
