// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  GatedVault
/// @author Sefa Tunçer
/// @notice ERC-4626 yield vault skeleton. Yield mechanics, decimals offset
///         (inflation defense), and Verifiable Credential gating are added
///         in subsequent atomic todos (10, 11, 12, 30+).
/// @dev    This is the policy-free shape: standard ERC-4626 surface, vanilla
///         deposit/withdraw, owner role reserved for harvest/pause logic
///         introduced later. The internal `_deposit` and `_withdraw` hooks
///         delegate straight to ERC4626 super-calls; future overrides will
///         add accounting (`_accountedAssets`), VC attestation checks, and
///         pause logic at this exact insertion point so the public ERC-4626
///         interface stays untouched (composability with aggregators).
contract GatedVault is ERC4626, Ownable, ReentrancyGuard {
    /// @notice Construct the vault around an underlying ERC-20 asset.
    /// @dev    Vault token name and symbol are derived from the asset's
    ///         own symbol so a single contract works for any 6-, 8-, or
    ///         18-decimal asset (USDC, WBTC, DAI). The owner role is
    ///         reserved for harvest and pause flows in later todos.
    /// @param  asset_ Underlying ERC-20 (must implement IERC20Metadata).
    /// @param  owner_ Initial owner address.
    constructor(
        IERC20Metadata asset_,
        address owner_
    )
        ERC4626(IERC20(address(asset_)))
        ERC20(string.concat("Gated ", asset_.symbol(), " Vault"), string.concat("g", asset_.symbol()))
        Ownable(owner_)
    { }

    /// @dev Internal deposit hook. Skeleton delegates to ERC4626. Future
    ///      overrides will add `_accountedAssets += assets`, attestation
    ///      verification, and pause check here, all before the super call.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Internal withdraw hook. Skeleton delegates to ERC4626. Future
    ///      overrides will add `_accountedAssets -= assets`, attestation
    ///      freshness check, and pause check here, all before the super call.
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    )
        internal
        override
    {
        super._withdraw(caller, receiver, owner_, assets, shares);
    }
}
