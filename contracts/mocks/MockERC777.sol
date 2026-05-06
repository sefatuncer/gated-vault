// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  MockERC777
/// @author Sefa Tunçer
/// @notice Minimal ERC-777-flavored token used only as a fixture to verify
///         the vault's constructor-time toxic-asset reject. Implements the
///         ERC-777 mandatory `granularity()` function (which plain ERC-20
///         does not), but is otherwise a vanilla ERC-20. Real ERC-777 has
///         a `tokensReceived` callback hook that opens reentrancy on every
///         transfer; that hook is the actual attack vector (Imbtc / dForce
///         April 2020, $25M loss). For the vault's reject test, the
///         existence of `granularity()` is the detection signal — the hook
///         itself does not need to be implemented.
/// @dev    Test-only fixture. Not deployable to production. The vault's
///         constructor probes `granularity()` via low-level staticcall;
///         success identifies the asset as ERC-777-flavored and the vault
///         reverts with `ERC777NotSupported`. See `GatedVault` constructor
///         for the detection path.
contract MockERC777 is ERC20 {
    constructor() ERC20("Mock ERC777", "M777") { }

    /// @notice ERC-777 mandatory: minimum increment by which token amounts
    ///         must be transferable. Returning 1 means "any amount", which
    ///         is the most common real-world value.
    /// @return The granularity (1, meaning any amount is transferable).
    function granularity() external pure returns (uint256) {
        return 1;
    }
}
