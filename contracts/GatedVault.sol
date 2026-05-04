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
    // -------- Yield: constants --------

    /// @notice Maximum permissible annual yield rate (basis points). 5_000 = 50% APY.
    /// @dev    Owner-abuse defense. Without this cap, a malicious or compromised
    ///         owner could set yieldRate to an arbitrary value and drain the
    ///         yield reserve in one harvest. 50% covers practical DeFi yield
    ///         ranges (Aave / Yearn V3 historical max ~30%) while keeping a
    ///         hard upper bound on the trust assumption.
    uint256 public constant MAX_YIELD_RATE = 5000;

    /// @notice Seconds in one nominal year, used for APY -> per-second math.
    /// @dev    Leap-year ignored; ~0.27% drift per year is accepted in exchange
    ///         for a constant-time formula. More precise constants (365.25 days)
    ///         add gas without meaningful value at realistic yield rates.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // -------- Yield: state --------

    /// @notice Annual yield rate in basis points (100 = 1% APY).
    uint256 public yieldRate;

    /// @notice Block timestamp of the last yield realization (harvest).
    /// @dev    Pending yield accrual is computed off `block.timestamp - lastHarvest`
    ///         in todo-12. Construction sets this to deploy time so the first
    ///         depositor does not retroactively accrue yield.
    uint256 public lastHarvest;

    /// @notice Total user-deposited principal (yield excluded).
    /// @dev    `totalAssets()` will be `principal + pendingYield()` in todo-13.
    ///         Tracked explicitly so external donations to the vault do not
    ///         warp share price (Sonne Finance Oct 2022 attack class).
    uint256 public principal;

    // -------- Yield: errors / events --------

    /// @notice Reverts when a yield rate above MAX_YIELD_RATE is requested.
    /// @param rate Requested rate (basis points).
    /// @param max  Configured ceiling (`MAX_YIELD_RATE`).
    error YieldRateTooHigh(uint256 rate, uint256 max);

    /// @notice Emitted when the yield rate changes.
    event YieldRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when accrued yield is realized as principal.
    event YieldHarvested(uint256 amount);

    /// @notice Construct the vault around an underlying ERC-20 asset.
    /// @dev    Vault token name and symbol are derived from the asset's
    ///         own symbol so a single contract works for any 6-, 8-, or
    ///         18-decimal asset (USDC, WBTC, DAI). The owner role is
    ///         reserved for harvest, pause, and yield-rate adjustment.
    ///         Trust assumption: owner can change yieldRate up to
    ///         `MAX_YIELD_RATE`; this is documented in the README's
    ///         "Trust Assumptions" section.
    /// @param  asset_            Underlying ERC-20 (must implement IERC20Metadata).
    /// @param  owner_            Initial owner address.
    /// @param  initialYieldRate  Starting yield rate in basis points; must be <= MAX_YIELD_RATE.
    constructor(
        IERC20Metadata asset_,
        address owner_,
        uint256 initialYieldRate
    )
        ERC4626(IERC20(address(asset_)))
        ERC20(string.concat("Gated ", asset_.symbol(), " Vault"), string.concat("g", asset_.symbol()))
        Ownable(owner_)
    {
        if (initialYieldRate > MAX_YIELD_RATE) {
            revert YieldRateTooHigh(initialYieldRate, MAX_YIELD_RATE);
        }
        yieldRate = initialYieldRate;
        lastHarvest = block.timestamp;
    }

    // -------- Yield: setter --------

    /// @notice Update the annual yield rate.
    /// @dev    `onlyOwner` because the rate change is a trust-bearing
    ///         decision affecting all share holders. Bounded by
    ///         `MAX_YIELD_RATE` to limit owner abuse: a compromised key
    ///         cannot promise an unbounded yield and drain the reserve.
    ///         **todo-12:** call `_harvest()` before the rate change so
    ///         yield accrued under the old rate is realized first; otherwise
    ///         pending yield is silently re-priced at the new rate.
    /// @param  newRate New rate in basis points (100 = 1% APY).
    function setYieldRate(uint256 newRate) external onlyOwner {
        if (newRate > MAX_YIELD_RATE) {
            revert YieldRateTooHigh(newRate, MAX_YIELD_RATE);
        }
        // todo-12: _harvest() — flush pending yield under old rate first
        uint256 oldRate = yieldRate;
        yieldRate = newRate;
        emit YieldRateUpdated(oldRate, newRate);
    }

    /// @notice Decimals offset for inflation-attack defense.
    /// @dev    Returns 6: matches USDC's decimal precision and is the audit-grade
    ///         floor for ERC-20 backing. The OZ virtual-shares pattern multiplies
    ///         the cost of an inflation attack by 10^offset, so an attacker must
    ///         lock 10^6 more capital to dilute a fresh depositor's shares to
    ///         zero. Combined with tracked `_accountedAssets` (todo-13) and an
    ///         atomic first-deposit seed in the deploy script (todo-78), this
    ///         makes the classic 1-wei + donation attack economically unfeasible.
    ///         References:
    ///           - EIP-4626 Inflation Attack discussion (Ethereum Magicians).
    ///           - OpenZeppelin v4.7+ ERC4626 virtual-shares change log.
    ///           - Sonne Finance Oct 2022 post-mortem (~$20M, donation oracle).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

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
