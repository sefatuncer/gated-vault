// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Whitelist } from "../../contracts/access/Whitelist.sol";

/// @title  WhitelistTest
/// @notice Unit tests for the RBAC whitelist registry. Covers constructor
///         role seeding, role hierarchy, single + batch writes, custom
///         revert + event surface, and the OZ AccessControl renounce
///         pitfall (a sole admin can brick the registry by renouncing
///         WHITELIST_ADMIN_ROLE — documented intentionally to keep the
///         trust assumption explicit).
contract WhitelistTest is Test {
    Whitelist internal whitelist;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    event Whitelisted(address indexed user, bool status);

    function setUp() public {
        whitelist = new Whitelist(admin);
    }

    // -------- Constructor / role hierarchy --------

    function test_ConstructorGrantsBothRoles() public view {
        assertTrue(whitelist.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin lacks DEFAULT_ADMIN_ROLE");
        assertTrue(whitelist.hasRole(WHITELIST_ADMIN_ROLE, admin), "admin lacks WHITELIST_ADMIN_ROLE");
    }

    function test_RoleAdminIsDefaultAdmin() public view {
        assertEq(whitelist.getRoleAdmin(WHITELIST_ADMIN_ROLE), DEFAULT_ADMIN_ROLE, "role-admin mismatch");
    }

    function test_StrangerHoldsNoRoles() public view {
        assertFalse(whitelist.hasRole(DEFAULT_ADMIN_ROLE, stranger), "stranger DEFAULT_ADMIN");
        assertFalse(whitelist.hasRole(WHITELIST_ADMIN_ROLE, stranger), "stranger WHITELIST_ADMIN");
    }

    // -------- setWhitelist --------

    function test_AdminCanWhitelist() public {
        vm.prank(admin);
        whitelist.setWhitelist(alice, true);

        assertTrue(whitelist.isWhitelisted(alice), "alice not whitelisted");
    }

    function test_NonAdminCannotWhitelist() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, WHITELIST_ADMIN_ROLE
            )
        );
        vm.prank(stranger);
        whitelist.setWhitelist(alice, true);
    }

    function test_RemoveWhitelist() public {
        vm.startPrank(admin);
        whitelist.setWhitelist(alice, true);
        assertTrue(whitelist.isWhitelisted(alice), "precondition: alice whitelisted");

        whitelist.setWhitelist(alice, false);
        assertFalse(whitelist.isWhitelisted(alice), "alice still whitelisted after revoke");
        vm.stopPrank();
    }

    function test_WhitelistedEventEmitted() public {
        vm.expectEmit(true, false, false, true, address(whitelist));
        emit Whitelisted(alice, true);

        vm.prank(admin);
        whitelist.setWhitelist(alice, true);
    }

    /// @dev Idempotent emission: setting the same status twice still emits.
    ///      Documented in Whitelist.sol NatSpec — off-chain indexers see
    ///      every admin intent, not only state transitions.
    function test_IdempotentEmissionOnSameStatus() public {
        vm.startPrank(admin);
        whitelist.setWhitelist(alice, true);

        vm.expectEmit(true, false, false, true, address(whitelist));
        emit Whitelisted(alice, true);
        whitelist.setWhitelist(alice, true);
        vm.stopPrank();

        assertTrue(whitelist.isWhitelisted(alice), "idempotent write changed state");
    }

    // -------- setWhitelistBatch --------

    function test_BatchWhitelist() public {
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;

        vm.prank(admin);
        whitelist.setWhitelistBatch(users, true);

        assertTrue(whitelist.isWhitelisted(alice), "alice");
        assertTrue(whitelist.isWhitelisted(bob), "bob");
        assertTrue(whitelist.isWhitelisted(carol), "carol");
    }

    function test_BatchWhitelistEmitsPerEntry() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.expectEmit(true, false, false, true, address(whitelist));
        emit Whitelisted(alice, true);
        vm.expectEmit(true, false, false, true, address(whitelist));
        emit Whitelisted(bob, true);

        vm.prank(admin);
        whitelist.setWhitelistBatch(users, true);
    }

    function test_BatchWhitelistEmptyArray() public {
        address[] memory users = new address[](0);

        vm.prank(admin);
        whitelist.setWhitelistBatch(users, true);

        // No-op: nothing to assert other than absence of revert.
        assertFalse(whitelist.isWhitelisted(alice), "empty batch leaked state");
    }

    function test_BatchWhitelistRemoveAll() public {
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;

        vm.startPrank(admin);
        whitelist.setWhitelistBatch(users, true);
        whitelist.setWhitelistBatch(users, false);
        vm.stopPrank();

        assertFalse(whitelist.isWhitelisted(alice), "alice");
        assertFalse(whitelist.isWhitelisted(bob), "bob");
        assertFalse(whitelist.isWhitelisted(carol), "carol");
    }

    function test_NonAdminCannotBatchWhitelist() public {
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, WHITELIST_ADMIN_ROLE
            )
        );
        vm.prank(stranger);
        whitelist.setWhitelistBatch(users, true);
    }

    // -------- checkWhitelisted --------

    function test_CheckWhitelistedRevertsForNonWhitelisted() public {
        vm.expectRevert(abi.encodeWithSelector(Whitelist.NotWhitelisted.selector, alice));
        whitelist.checkWhitelisted(alice);
    }

    function test_CheckWhitelistedSucceedsForWhitelisted() public {
        vm.prank(admin);
        whitelist.setWhitelist(alice, true);

        // No revert expected; staticcall semantics — if it returns, it passed.
        whitelist.checkWhitelisted(alice);
    }

    // -------- Role administration --------

    function test_GrantWhitelistAdminRole() public {
        vm.prank(admin);
        whitelist.grantRole(WHITELIST_ADMIN_ROLE, alice);

        assertTrue(whitelist.hasRole(WHITELIST_ADMIN_ROLE, alice), "alice not granted");

        vm.prank(alice);
        whitelist.setWhitelist(bob, true);
        assertTrue(whitelist.isWhitelisted(bob), "bob not whitelisted by new admin");
    }

    function test_RevokeWhitelistAdminRole() public {
        vm.startPrank(admin);
        whitelist.grantRole(WHITELIST_ADMIN_ROLE, alice);
        whitelist.revokeRole(WHITELIST_ADMIN_ROLE, alice);
        vm.stopPrank();

        assertFalse(whitelist.hasRole(WHITELIST_ADMIN_ROLE, alice), "alice still admin");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, WHITELIST_ADMIN_ROLE
            )
        );
        vm.prank(alice);
        whitelist.setWhitelist(bob, true);
    }

    function test_NonDefaultAdminCannotGrantRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(stranger);
        whitelist.grantRole(WHITELIST_ADMIN_ROLE, alice);
    }

    /// @dev Renounce-bricks-contract pitfall: a sole admin renouncing
    ///      WHITELIST_ADMIN_ROLE leaves the registry unwritable. OZ v5
    ///      requires `callerConfirmation == _msgSender()`, so the call
    ///      shape below mirrors the only legal way to renounce. Test
    ///      makes the consequence explicit instead of leaving it as an
    ///      undocumented inherited behavior.
    function test_RenounceRoleBricksRegistryWhenSoleAdmin() public {
        vm.prank(admin);
        whitelist.renounceRole(WHITELIST_ADMIN_ROLE, admin);

        assertFalse(whitelist.hasRole(WHITELIST_ADMIN_ROLE, admin), "renounce did not clear role");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, WHITELIST_ADMIN_ROLE
            )
        );
        vm.prank(admin);
        whitelist.setWhitelist(alice, true);
    }
}
