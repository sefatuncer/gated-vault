// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
    using SafeERC20 for IERC20;

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

    /// @notice Reverts when the underlying asset implements ERC-777 semantics.
    /// @dev    The vault rejects ERC-777 at construction because its
    ///         `tokensReceived` hook opens a reentrancy path on every
    ///         `transfer` (Imbtc / dForce April 2020, $25M loss). Detection
    ///         probes for `granularity()` (mandatory in ERC-777, absent in
    ///         plain ERC-20) via low-level staticcall.
    error ERC777NotSupported();

    /// @notice Reverts on a zero-asset deposit or withdraw.
    /// @dev    ERC-4626 does not forbid zero amounts, but they are pure
    ///         gas waste and event spam: a successful zero-deposit emits
    ///         a meaningless `Deposit` log that off-chain indexers must
    ///         either count or filter. Audit-grade vaults (Yearn V3,
    ///         Morpho) reject at the boundary.
    error ZeroAssets();

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

        // Toxic asset filter: ERC-777 mandates `granularity()`; ERC-20 has no
        // such function. A successful staticcall to `granularity()` therefore
        // identifies the asset as ERC-777-flavored, which the vault refuses
        // because `tokensReceived` hooks would expose every transfer to a
        // reentrancy callback (Imbtc / dForce April 2020, $25M loss).
        // ERC-1820 registry probing is the more "canonical" path; this
        // staticcall variant is dependency-free and sufficient for the
        // standard ERC-777 implementations in the wild.
        (bool isERC777,) = address(asset_).staticcall(abi.encodeWithSignature("granularity()"));
        if (isERC777) {
            revert ERC777NotSupported();
        }

        yieldRate = initialYieldRate;
        lastHarvest = block.timestamp;
    }

    // -------- ERC-4626 accounting override --------

    /// @inheritdoc ERC4626
    /// @dev Tracked AUM = `principal + pendingYield()`. The OZ default
    ///      `IERC20(asset).balanceOf(address(this))` is donation-warpable
    ///      (Sonne 2022, Cream 2021); this override breaks the donation
    ///      oracle attack class by ignoring tokens that arrived outside of
    ///      the documented entry points (`deposit`, `mint`, `harvest`,
    ///      `depositYieldReserve`). Pending yield is included so share
    ///      conversions reflect accrual without forcing a write on every
    ///      read.
    function totalAssets() public view override returns (uint256) {
        return principal + pendingYield();
    }

    // -------- Yield: setter --------

    /// @notice Update the annual yield rate.
    /// @dev    `onlyOwner` because the rate change is a trust-bearing
    ///         decision affecting all share holders. Bounded by
    ///         `MAX_YIELD_RATE` to limit owner abuse: a compromised key
    ///         cannot promise an unbounded yield and drain the reserve.
    ///         Pending yield under the old rate is realized via
    ///         `_harvestYield()` first so the new rate cannot silently
    ///         re-price yield that was already accrued.
    /// @param  newRate New rate in basis points (100 = 1% APY).
    function setYieldRate(uint256 newRate) external onlyOwner {
        if (newRate > MAX_YIELD_RATE) {
            revert YieldRateTooHigh(newRate, MAX_YIELD_RATE);
        }
        _harvestYield();
        uint256 oldRate = yieldRate;
        yieldRate = newRate;
        emit YieldRateUpdated(oldRate, newRate);
    }

    // -------- Yield: accrual + harvest --------

    /// @notice Yield accrued since the last harvest, in asset units.
    /// @dev    Simple interest:
    ///         `(principal × yieldRate × elapsed) / (10_000 × SECONDS_PER_YEAR)`
    ///         Returns 0 when principal is zero (avoids meaningless math
    ///         and a divide-by-zero-style result of pure constants).
    /// @return The amount of asset that would be realized as principal if
    ///         `harvest()` were called now.
    function pendingYield() public view returns (uint256) {
        if (principal == 0) return 0;
        uint256 elapsed = block.timestamp - lastHarvest;
        return (principal * yieldRate * elapsed) / (10_000 * SECONDS_PER_YEAR);
    }

    /// @notice Realizes accrued yield, increasing `principal` by the
    ///         harvested amount. Anyone can call.
    /// @dev    Pure accounting realization; no external value transfer.
    ///         Exists so keepers / aggregators can flush state without
    ///         needing the owner role. Bounded by available reserve so
    ///         a yield-rate misconfiguration cannot mint principal that
    ///         is not actually backed by tokens in the vault.
    /// @return harvested The amount realized this call.
    function harvest() external returns (uint256 harvested) {
        return _harvestYield();
    }

    /// @notice Allows the owner to top up the yield reserve.
    /// @dev    The reserve is the gap between the vault's asset balance and
    ///         tracked `principal`. Donations to that gap are what the
    ///         `harvest()` flow draws from. Trust assumption: only the
    ///         owner is supposed to fund the reserve; documented in the
    ///         README's Trust Assumptions section.
    /// @param  amount Asset units to pull from the caller.
    function depositYieldReserve(uint256 amount) external onlyOwner {
        // Reserve is intentionally NOT added to `principal`: principal tracks
        // user-deposited AUM, while the reserve is the buffer harvest draws
        // against. Mixing the two would let donations inflate share price,
        // which is the exact pattern the tracked-AUM rule (todo-13) prevents.
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @dev Internal harvest core. Bounded by available reserve so a
    ///      yield rate that briefly exceeds reserve cannot mint principal
    ///      that is not actually backed by tokens in the vault. Emits
    ///      `YieldHarvested` only when something was realized.
    function _harvestYield() internal returns (uint256 yield_) {
        yield_ = pendingYield();
        if (yield_ == 0) {
            lastHarvest = block.timestamp;
            return 0;
        }

        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 reserve = vaultBalance > principal ? vaultBalance - principal : 0;

        if (yield_ > reserve) {
            yield_ = reserve;
        }

        if (yield_ > 0) {
            principal += yield_;
            emit YieldHarvested(yield_);
        }
        lastHarvest = block.timestamp;
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

    /// @dev Internal deposit hook. Rejects zero-amount calls, then realizes
    ///      pending yield so the new depositor mints shares against an
    ///      up-to-date `totalAssets()`, and finally increments tracked
    ///      `principal`. Future overrides will add VC attestation checks
    ///      and pause logic at this exact insertion point.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets == 0) revert ZeroAssets();
        _harvestYield();
        super._deposit(caller, receiver, assets, shares);
        principal += assets;
    }

    /// @dev Internal withdraw hook. Rejects zero-amount calls, realizes
    ///      pending yield so share-to-asset conversion reflects accrual
    ///      up to this block, then decrements `principal`.
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
        if (assets == 0) revert ZeroAssets();
        _harvestYield();
        super._withdraw(caller, receiver, owner_, assets, shares);
        principal -= assets;
    }
}
