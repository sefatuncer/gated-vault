// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, Vm } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Whitelist } from "../../contracts/access/Whitelist.sol";

/// @title  WhitelistFuzzTest
/// @author Sefa Tunçer
/// @notice Property-based tests for the RBAC allow-list registry. The unit
///         suite (todo-24) covers single + batch happy paths and the revert
///         surface; this file pins five batch-mode invariants under random
///         array shapes — full forward consistency, add+remove round-trip,
///         duplicate-entry behaviour, empty-batch no-op, and non-admin
///         rejection.
contract WhitelistFuzzTest is Test {
    Whitelist internal whitelist;

    address internal admin = makeAddr("admin");
    bytes32 internal constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    function setUp() public {
        whitelist = new Whitelist(admin);
    }

    /// @notice Every entry written through `setWhitelistBatch` reads back
    ///         with the same status afterwards.
    /// @dev    Length bounded `(0, 100]`: zero would call into the empty
    ///         loop (covered separately) and 100 already exercises duplicate
    ///         distribution patterns at realistic batch sizes. Address
    ///         elements are left unfiltered — `address(0)` is a valid
    ///         mapping key for `isWhitelisted` and must round-trip too.
    function testFuzz_BatchWhitelistConsistency(address[] calldata users) public {
        vm.assume(users.length > 0 && users.length <= 100);

        vm.prank(admin);
        whitelist.setWhitelistBatch(users, true);

        uint256 len = users.length;
        for (uint256 i = 0; i < len; ++i) {
            assertTrue(whitelist.isWhitelisted(users[i]), "entry missing after batch add");
        }
    }

    /// @notice Add-batch followed by remove-batch with the same array leaves
    ///         the registry indistinguishable from a fresh deploy.
    /// @dev    Round-trip property. Duplicate addresses inside `users`
    ///         hit the same slot twice on the way in and twice on the way
    ///         out; the final state is still `false` because the last
    ///         write wins. Important invariant for indexers that maintain
    ///         a mirrored set off-chain.
    function testFuzz_RemoveBatchAfterAdd(address[] calldata users) public {
        vm.assume(users.length > 0 && users.length <= 100);

        vm.startPrank(admin);
        whitelist.setWhitelistBatch(users, true);
        whitelist.setWhitelistBatch(users, false);
        vm.stopPrank();

        uint256 len = users.length;
        for (uint256 i = 0; i < len; ++i) {
            assertFalse(whitelist.isWhitelisted(users[i]), "entry not cleared after batch remove");
        }
    }

    /// @notice An address that appears twice in the same batch ends up with
    ///         the requested status (last write wins), and the contract
    ///         still emits one `Whitelisted` event per array slot.
    /// @dev    `dupIndex` picks an existing entry inside `users`; the
    ///         duplicated batch is built in memory by appending that
    ///         address to a copy. Event count is verified via
    ///         `vm.recordLogs` so off-chain consumers can trust
    ///         "one event per input entry" regardless of dedup.
    function testFuzz_DuplicateAddressesInBatch(address[] calldata users, uint8 dupIndex) public {
        vm.assume(users.length >= 1 && users.length <= 50);
        uint256 idx = bound(dupIndex, 0, users.length - 1);

        address[] memory padded = new address[](users.length + 1);
        for (uint256 i = 0; i < users.length; ++i) {
            padded[i] = users[i];
        }
        padded[users.length] = users[idx];

        vm.recordLogs();
        vm.prank(admin);
        whitelist.setWhitelistBatch(padded, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, padded.length, "one event per slot (no dedup)");
        assertTrue(whitelist.isWhitelisted(padded[idx]), "duplicated address must be whitelisted");
        for (uint256 i = 0; i < users.length; ++i) {
            assertTrue(whitelist.isWhitelisted(users[i]), "original entry missing");
        }
    }

    /// @notice An empty batch is a pure no-op — no state change, no events,
    ///         regardless of the `status` argument.
    /// @dev    Important for callers that build batches dynamically and may
    ///         end up with an empty list at the edge (e.g. an off-chain
    ///         indexer that filtered everything out). The contract must
    ///         tolerate the degenerate input without reverting or polluting
    ///         the event stream.
    function testFuzz_EmptyBatchNoOp(bool status) public {
        address[] memory empty = new address[](0);

        vm.recordLogs();
        vm.prank(admin);
        whitelist.setWhitelistBatch(empty, status);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "empty batch must not emit");
    }

    /// @notice Anyone who is not the `WHITELIST_ADMIN_ROLE` holder is
    ///         rejected with the OZ v5 access-control custom error.
    /// @dev    Address space is filtered against `admin` and `address(0)`
    ///         (Foundry's `vm.prank(address(0))` is not well-defined). The
    ///         test exercises the modifier path for arbitrary callers and
    ///         arbitrary batch shapes; both inputs are fuzzed so any
    ///         interaction between size and access fails loudly.
    function testFuzz_NonAdminBatchReverts(address caller, address[] calldata users) public {
        vm.assume(caller != admin && caller != address(0));
        vm.assume(users.length > 0 && users.length <= 50);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, WHITELIST_ADMIN_ROLE
            )
        );
        whitelist.setWhitelistBatch(users, true);
    }
}
