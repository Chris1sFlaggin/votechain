// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Errors} from "../utils/Errors.sol";

/// @title Roles — minimal, dependency-free access control.
/// @notice ADMIN manages roles; ORACLE is the (simulated) SPID oracle that may seed
///         identities. Kept self-contained (no OpenZeppelin) so the package builds
///         with nothing but solc.
abstract contract Roles {
    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32 public constant ORACLE = keccak256("ORACLE");

    mapping(bytes32 => mapping(address => bool)) private _has;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed by);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed by);

    constructor(address admin) {
        _grant(ADMIN, admin);
    }

    modifier onlyRole(bytes32 role) {
        if (!_has[role][msg.sender]) revert Errors.Unauthorized(role);
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _has[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyRole(ADMIN) {
        _grant(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(ADMIN) {
        _has[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }

    function _grant(bytes32 role, address account) internal {
        _has[role][account] = true;
        emit RoleGranted(role, account, msg.sender);
    }
}
