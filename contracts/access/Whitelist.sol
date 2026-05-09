// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title  Whitelist
/// @author Sefa Tunçer
/// @notice Role-based access registry. Marks addresses that the vault is
///         willing to serve before a Verifiable Credential proof is required
///         on-chain (Faz 3, todo-30+). After VC verification ships this
///         contract may be replaced or kept as an admin-managed fallback
///         path; the public surface (`isWhitelisted`, `checkWhitelisted`)
///         is intentionally narrow so swapping the implementation behind a
///         shared `IAccessChecker` interface stays cheap.
/// @dev    Two roles intentionally split:
///           - `DEFAULT_ADMIN_ROLE` — manages role membership itself
///             (`grantRole` / `revokeRole`), expected to live behind a
///             timelock or multisig in production.
///           - `WHITELIST_ADMIN_ROLE` — only writes the address book; can
///             be granted to a hot key for day-to-day operations without
///             handing over role-management power.
///         At construction both roles are granted to the same `admin`
///         address so the contract is usable out of the box; the production
///         deployment is expected to revoke `WHITELIST_ADMIN_ROLE` from the
///         admin and grant it to a separate operator key. This separation
///         is the trust assumption documented for v0.2.0.
contract Whitelist is AccessControl {
    /// @notice Role authorized to write `isWhitelisted` entries.
    /// @dev    Distinct from `DEFAULT_ADMIN_ROLE` so the address book can be
    ///         maintained by a hot operator key while role membership stays
    ///         under a colder admin key.
    bytes32 public constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    /// @notice Returns whether `user` is on the allow list.
    /// @dev    Public mapping; the auto-generated getter doubles as the
    ///         on-chain read path used by `checkWhitelisted` and by future
    ///         vault hooks (todo-25). Default value `false` means a fresh
    ///         address is rejected — fail-closed by construction.
    mapping(address user => bool whitelisted) public isWhitelisted;

    /// @notice Reverts when `checkWhitelisted` is called for an address that
    ///         is not on the allow list.
    /// @param  user The address that failed the check.
    error NotWhitelisted(address user);

    /// @notice Emitted whenever an address's whitelist status is written.
    /// @param  user   The affected address.
    /// @param  status The new value (true = whitelisted, false = removed).
    event Whitelisted(address indexed user, bool status);

    /// @notice Construct the registry, seeding both roles to `admin`.
    /// @dev    Production deployments are expected to immediately split the
    ///         two roles across distinct keys (see the contract-level
    ///         developer note above).
    /// @param  admin Initial holder of `DEFAULT_ADMIN_ROLE` and
    ///               `WHITELIST_ADMIN_ROLE`.
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(WHITELIST_ADMIN_ROLE, admin);
    }

    /// @notice Set the whitelist status of a single address.
    /// @dev    `onlyRole(WHITELIST_ADMIN_ROLE)` so role-management power and
    ///         day-to-day list curation can be held by separate keys. Idempotent
    ///         writes (same status twice) still emit `Whitelisted` so off-chain
    ///         indexers see every admin intent, not only state transitions.
    /// @param  user   Address to update.
    /// @param  status New status: true to allow, false to revoke.
    function setWhitelist(address user, bool status) external onlyRole(WHITELIST_ADMIN_ROLE) {
        isWhitelisted[user] = status;
        emit Whitelisted(user, status);
    }

    /// @notice Batch variant of `setWhitelist` applying the same status to
    ///         every entry.
    /// @dev    Loop emits one event per address so off-chain consumers do
    ///         not have to know that a batch was used. The cost grows
    ///         linearly with `users.length`; callers are expected to size
    ///         batches against the target chain's block gas limit (a
    ///         caller-side concern, not enforced on-chain to avoid an
    ///         arbitrary cap).
    /// @param  users  Addresses to update.
    /// @param  status New status applied to every entry.
    function setWhitelistBatch(address[] calldata users, bool status) external onlyRole(WHITELIST_ADMIN_ROLE) {
        uint256 len = users.length;
        for (uint256 i; i < len; ++i) {
            isWhitelisted[users[i]] = status;
            emit Whitelisted(users[i], status);
        }
    }

    /// @notice Reverts with `NotWhitelisted(user)` if `user` is not on the
    ///         allow list. Returns silently otherwise.
    /// @dev    `external view` so the future vault integration (todo-25)
    ///         can reach it via `staticcall` from `_deposit` / `_withdraw`
    ///         hooks without any state-mutation surface. Custom error keeps
    ///         the revert reason cheap and ABI-decodable.
    /// @param  user Address to check.
    function checkWhitelisted(address user) external view {
        if (!isWhitelisted[user]) revert NotWhitelisted(user);
    }
}
