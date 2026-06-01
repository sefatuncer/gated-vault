// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Whitelist } from "./access/Whitelist.sol";
import { IdentityVerifier } from "./identity/IdentityVerifier.sol";

/// @title  GatedVault
/// @author Sefa Tunçer
/// @notice ERC-4626 yield vault. Active defenses: simple-interest yield
///         with reserve-bounded harvest, virtual-shares decimals offset
///         (inflation defense), tracked-AUM `totalAssets` (donation oracle
///         defense), constructor-time ERC-777 reject (toxic-asset filter),
///         and an RBAC `Whitelist` registry plus an optional
///         `IdentityVerifier` (EIP-712 Verifiable Credential attestations)
///         that gate the deposit path (share recipients must be on the
///         allow list OR carry a live attestation). The public ERC-4626
///         surface stays untouched so aggregator composability is
///         preserved; `depositWithAttestation` is an additive entry point.
/// @dev    The internal `_deposit` and `_withdraw` hooks already realize
///         pending yield (temporal fairness across depositors) and update
///         tracked `principal`. `_deposit` additionally calls
///         `_enforceGate(receiver)` so the share *holder* is gated (not the
///         relayer / caller): the receiver passes if it holds a live
///         attestation (`identityVerifier.attestedUntil(receiver) >=
///         block.timestamp`) or, failing that, is on the `Whitelist`.
///         When `identityVerifier` is the zero address the vault runs in
///         whitelist-only mode and the gate is byte-identical to v0.2.0.
///         Withdraw is intentionally
///         ungated — once funds are in, the depositor must always be able
///         to exit, even if the admin later removes the address. Share
///         transfers between EOAs are not gated in v0.2.0; an `_update`
///         hook check lands together with the VC verifier in Faz 3. Owner
///         role is reserved for `setYieldRate` (bounded by
///         `MAX_YIELD_RATE`) and `depositYieldReserve`.
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
    /// @dev    Pending yield accrues as `block.timestamp - lastHarvest`.
    ///         Construction sets this to deploy time so the first depositor
    ///         does not retroactively accrue yield.
    uint256 public lastHarvest;

    /// @notice Total user-deposited principal (yield excluded).
    /// @dev    `totalAssets()` returns `principal + pendingYield()`. Tracked
    ///         explicitly so external donations to the vault do not warp
    ///         share price (Sonne Finance Oct 2022 donation oracle attack
    ///         class). Mutates only at documented entry points: `_deposit`
    ///         (`+= assets`), `_withdraw` (`-= assets`), `_harvestYield`
    ///         (`+= realized`).
    uint256 public principal;

    // -------- Whitelist gating --------

    /// @notice RBAC allow-list checked on the deposit path.
    /// @dev    Wired at construction and `immutable` so deposits avoid an
    ///         SLOAD; the address book lives in the `Whitelist` contract
    ///         itself, which is mutable via its own admin role. Swapping
    ///         the registry would require a vault redeploy, which is the
    ///         intended posture: the on-chain trust assumption is "this
    ///         specific Whitelist", not "whatever Whitelist the owner
    ///         chooses today". Replacement path in Faz 3 is a fresh vault
    ///         with the VC verifier wired into the same hook insertion
    ///         point.
    Whitelist public immutable whitelist;

    /// @notice Optional EIP-712 Verifiable Credential attestation gate.
    /// @dev    Wired at construction and `immutable` for the same trust
    ///         posture as `whitelist`: the on-chain assumption is "this
    ///         specific verifier", not "whatever the owner re-points to".
    ///         A live attestation
    ///         (`attestedUntil(receiver) >= block.timestamp`) lets a
    ///         receiver deposit even when absent from the whitelist
    ///         (Variant A: the credential is the stronger auth). The zero
    ///         address is a valid configuration meaning "VC path disabled,
    ///         whitelist-only" — it keeps the v0.2.0 deploy shape and the
    ///         existing test surface working unchanged. The gate reads
    ///         `attestedUntil`, a session record set by
    ///         `IdentityVerifier.consumeAttestation`: an attestation is a
    ///         time-boxed deposit window, not a per-deposit proof. When
    ///         `requiredCredentialType` is non-zero the gate additionally
    ///         reads `attestedCredentialType(receiver)` and requires it to
    ///         match. That second read is what makes the type check
    ///         non-bypassable: the type is recorded on the verifier (which
    ///         every consume routes through), so a caller who consumes an
    ///         attestation directly — skipping the vault — still leaves the
    ///         consumed type on record and is rejected if it does not match.
    IdentityVerifier public immutable identityVerifier;

    /// @notice Credential type the deposit gate requires (zero = accept any).
    /// @dev    Mutable owner *policy*, not an immutable trust anchor: which
    ///         KYC / credential standard the vault accepts is expected to
    ///         change over time (e.g. migrating from one schema to a newer
    ///         one), so unlike `identityVerifier` (the trust anchor) this is
    ///         owner-settable via `setRequiredCredentialType`. The zero
    ///         value disables the type filter, so a freshly deployed vault
    ///         accepts any trusted-signed attestation until the owner pins a
    ///         type. Matched against `IdentityVerifier.attestedCredentialType`
    ///         in `_enforceGate` and against the supplied `credentialHash`
    ///         in `depositWithAttestation`. Documented in the README's Trust
    ///         Assumptions section alongside `setYieldRate`.
    bytes32 public requiredCredentialType;

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

    /// @notice Reverts when the constructor receives the zero address for
    ///         the whitelist registry.
    /// @dev    Fail-loud at construction. Without this guard every deposit
    ///         would emit a staticcall to address(0) whose empty return
    ///         data decodes to a successful no-op, silently bypassing the
    ///         allow-list check — the opposite of fail-closed.
    error ZeroWhitelist();

    /// @notice Reverts when `depositWithAttestation` is given an attestation
    ///         whose credential type does not match `requiredCredentialType`.
    /// @dev    Raised before the attestation is consumed, so a wrong-type
    ///         attempt does not burn the nonce. The gate-level check in
    ///         `_enforceGate` is the security-critical one (it also closes
    ///         the direct-consume path); this early revert is the clear-UX
    ///         counterpart on the vault's own entry point.
    /// @param provided The credential type carried by the supplied attestation.
    /// @param required The credential type the vault currently requires.
    error CredentialTypeMismatch(bytes32 provided, bytes32 required);

    /// @notice Reverts on a zero-asset deposit or withdraw.
    /// @dev    ERC-4626 does not forbid zero amounts, but they are pure
    ///         gas waste and event spam: a successful zero-deposit emits
    ///         a meaningless `Deposit` log that off-chain indexers must
    ///         either count or filter. Audit-grade vaults (Yearn V3,
    ///         Morpho) reject at the boundary.
    error ZeroAssets();

    /// @notice Emitted when the yield rate changes.
    /// @param oldRate Previous rate (basis points).
    /// @param newRate New rate (basis points).
    event YieldRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when accrued yield is realized as principal.
    /// @param amount Yield realized in this harvest, in asset units.
    event YieldHarvested(uint256 amount);

    /// @notice Emitted when the owner changes the required credential type.
    /// @param oldType Previous required type (zero = no filter).
    /// @param newType New required type (zero = disable the filter).
    event RequiredCredentialTypeUpdated(bytes32 oldType, bytes32 newType);

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
    /// @param  whitelist_        Allow-list registry checked in `_deposit`; must be non-zero.
    /// @param  identityVerifier_ VC attestation gate; the zero address
    ///                           disables the attestation path (whitelist-only mode).
    constructor(
        IERC20Metadata asset_,
        address owner_,
        uint256 initialYieldRate,
        Whitelist whitelist_,
        IdentityVerifier identityVerifier_
    )
        ERC4626(IERC20(address(asset_)))
        ERC20(string.concat("Gated ", asset_.symbol(), " Vault"), string.concat("g", asset_.symbol()))
        Ownable(owner_)
    {
        if (initialYieldRate > MAX_YIELD_RATE) {
            revert YieldRateTooHigh(initialYieldRate, MAX_YIELD_RATE);
        }
        if (address(whitelist_) == address(0)) {
            revert ZeroWhitelist();
        }

        // Toxic asset filter: ERC-777 mandates `granularity()`; ERC-20 has no
        // such function. A successful staticcall to `granularity()` therefore
        // identifies the asset as ERC-777-flavored, which the vault refuses
        // because `tokensReceived` hooks would expose every transfer to a
        // reentrancy callback (Imbtc / dForce April 2020, $25M loss).
        // ERC-1820 registry probing is the more "canonical" path; this
        // staticcall variant is dependency-free and sufficient for the
        // standard ERC-777 implementations in the wild.
        // slither-disable-next-line low-level-calls
        (bool isERC777,) = address(asset_).staticcall(abi.encodeWithSignature("granularity()"));
        if (isERC777) {
            revert ERC777NotSupported();
        }

        whitelist = whitelist_;
        identityVerifier = identityVerifier_;
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

    // -------- VC attestation deposit --------

    /// @notice Deposit `assets` for `receiver` by presenting a fresh EIP-712
    ///         attestation, bypassing the whitelist requirement.
    /// @dev    Consumes the attestation on `identityVerifier` first
    ///         (validates expiry / replay / signer, marks the nonce used,
    ///         and records `attestedUntil[receiver] = expiry`), then routes
    ///         through the standard `deposit` entry point. The subsequent
    ///         `_enforceGate(receiver)` inside `_deposit` reads the
    ///         just-written `attestedUntil` and passes, so a receiver that
    ///         is not on the whitelist still gets in (Variant A). Because
    ///         `expiry >= block.timestamp` is guaranteed by `consumeAttestation`'s
    ///         strict `expiry < block.timestamp` reject, the `>=` gate
    ///         cannot fail on the equality boundary. Order is
    ///         Checks-Effects-Interactions: the attestation effect lands on
    ///         the verifier before the asset `transferFrom` in `deposit`.
    ///         `nonReentrant` guards the two external interactions
    ///         (`consumeAttestation`, then `deposit` -> `transferFrom`);
    ///         ERC-777 assets are already rejected at construction, so the
    ///         guard is defense-in-depth rather than the sole barrier.
    ///         Reverts propagate the verifier's typed errors
    ///         (`AttestationExpired`, `AttestationReplayed`,
    ///         `UntrustedSigner`, `SignatureInvalid`) unchanged. Requires a
    ///         non-zero `identityVerifier`; in whitelist-only mode the call
    ///         reverts when it dispatches to the zero address. When
    ///         `requiredCredentialType` is set, a `credentialHash` that does
    ///         not match it reverts early with `CredentialTypeMismatch`
    ///         before the attestation is consumed, so a wrong-type attempt
    ///         does not burn the nonce.
    /// @param  assets         Asset units to pull from the caller.
    /// @param  receiver       Share recipient; also the attestation subject (`user`).
    /// @param  credentialHash Credential type / schema identifier; must equal
    ///                        `requiredCredentialType` when that is non-zero.
    /// @param  expiry         Attestation expiry (UNIX); must be >= now at consume time.
    /// @param  nonce          Single-use attestation nonce.
    /// @param  signature      65-byte (r||s||v) signature over the typed-data digest.
    /// @return shares         Vault shares minted to `receiver`.
    function depositWithAttestation(
        uint256 assets,
        address receiver,
        bytes32 credentialHash,
        uint64 expiry,
        bytes32 nonce,
        bytes calldata signature
    )
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (requiredCredentialType != bytes32(0) && credentialHash != requiredCredentialType) {
            revert CredentialTypeMismatch(credentialHash, requiredCredentialType);
        }
        IdentityVerifier.Attestation memory attestation = IdentityVerifier.Attestation({
            user: receiver, credentialHash: credentialHash, expiry: expiry, nonce: nonce
        });
        identityVerifier.consumeAttestation(attestation, signature);
        return deposit(assets, receiver);
    }

    /// @dev Internal harvest core. Bounded by available reserve so a
    ///      yield rate that briefly exceeds reserve cannot mint principal
    ///      that is not actually backed by tokens in the vault. Emits
    ///      `YieldHarvested` only when something was realized.
    /// @return yield_ Asset units realized as principal in this call.
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

    /// @dev Internal deposit hook. Order:
    ///      1. reject zero-amount,
    ///      2. reject a *receiver* that passes neither gate (attestation
    ///         or whitelist) via `_enforceGate`,
    ///      3. realize pending yield so the new depositor mints shares
    ///         against an up-to-date `totalAssets()`,
    ///      4. delegate to OZ ERC-4626 (transferFrom + mint),
    ///      5. update tracked `principal`.
    ///      The gating check sits before `_harvestYield` so a rejected
    ///      deposit costs no state writes (no unexpected event emission,
    ///      no `lastHarvest` stamp). This single insertion point serves
    ///      both the plain ERC-4626 entry points and
    ///      `depositWithAttestation`; the ERC-4626 ABI stays unchanged.
    /// @param caller   ERC-4626 caller (msg.sender of the public entry point).
    /// @param receiver Address that receives the minted shares; must pass `_enforceGate`.
    /// @param assets   Asset units pulled from caller, added to `principal`.
    /// @param shares   Share units minted to receiver (precomputed by ERC-4626 super).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets == 0) revert ZeroAssets();
        _enforceGate(receiver);
        _harvestYield();
        super._deposit(caller, receiver, assets, shares);
        principal += assets;
    }

    /// @dev Deposit gate for the share *receiver*. Passes if the receiver
    ///      holds a live VC attestation of the required type, otherwise
    ///      falls back to the whitelist. The attestation arm requires three
    ///      things together: a wired verifier, a live session
    ///      (`attestedUntil(receiver) >= now`), and — when
    ///      `requiredCredentialType` is non-zero — a recorded credential
    ///      type that matches it. The type clause is what closes the
    ///      direct-consume bypass: because `attestedCredentialType` is
    ///      written on the verifier by every consume, an address that
    ///      consumed a wrong-type attestation directly still fails here.
    ///      Order matters for two reasons: (1) the attestation is the
    ///      stronger auth (Variant A — a valid credential lets an address in
    ///      even if it was never whitelisted); (2) checking the verifier
    ///      address first keeps the whitelist-only path byte-identical to
    ///      v0.2.0 — when `identityVerifier` is the zero address the `&&`
    ///      short-circuits and `whitelist.checkWhitelisted` runs exactly as
    ///      before, reverting with `NotWhitelisted`. A receiver that clears
    ///      neither arm therefore still reverts with the familiar
    ///      `Whitelist.NotWhitelisted(receiver)`.
    /// @param receiver Address that must clear at least one gate.
    function _enforceGate(address receiver) internal view {
        if (
            address(identityVerifier) != address(0) && identityVerifier.attestedUntil(receiver) >= block.timestamp
                && (requiredCredentialType == bytes32(0)
                    || identityVerifier.attestedCredentialType(receiver) == requiredCredentialType)
        ) {
            return;
        }
        whitelist.checkWhitelisted(receiver);
    }

    /// @notice Set the credential type the deposit gate requires.
    /// @dev    `onlyOwner` because it is a trust-bearing policy change
    ///         affecting who can deposit. Setting it to zero disables the
    ///         type filter (any trusted-signed attestation passes); setting
    ///         a new non-zero type immediately stops attestations of the old
    ///         type from clearing the gate, even ones already consumed
    ///         within their window (their recorded `attestedCredentialType`
    ///         no longer matches). This is the intended migration lever for
    ///         moving to a new KYC standard.
    /// @param  newType New required credential type (zero = accept any).
    function setRequiredCredentialType(bytes32 newType) external onlyOwner {
        emit RequiredCredentialTypeUpdated(requiredCredentialType, newType);
        requiredCredentialType = newType;
    }

    /// @dev Internal withdraw hook. Rejects zero-amount calls, realizes
    ///      pending yield so share-to-asset conversion reflects accrual
    ///      up to this block, then decrements `principal`.
    /// @param caller   ERC-4626 caller (msg.sender of the public entry point).
    /// @param receiver Address that receives the underlying asset.
    /// @param owner_   Share holder being charged for the withdrawal.
    /// @param assets   Asset units sent to receiver, subtracted from `principal`.
    /// @param shares   Share units burned from `owner_` (precomputed by ERC-4626 super).
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
