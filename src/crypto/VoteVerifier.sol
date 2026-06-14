// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VoteVerifier — the cryptographic core: digest + verifica()
/// @notice The on-chain digest of a vote is keccak256(abi.encodePacked(vote, nonce))
///         (the spec's `Keccak256(voto + nonce)`). The vote is a bytes32 option id,
///         the nonce is the voter's secret string.
library VoteVerifier {
    /// @notice digest = keccak256(voto + nonce).
    function digest(bytes32 vote, string memory nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(vote, nonce));
    }

    /// @notice Does (vote, nonce) hash to the stored digest? (reveal / tally check)
    function matches(bytes32 vote, string memory nonce, bytes32 stored) internal pure returns (bool) {
        return digest(vote, nonce) == stored;
    }

    /// @notice verifica(): is `d` still free in this referendum's digest domain?
    /// @dev Returns true when the digest is NEW (not yet used), i.e. the uniqueness
    ///      check passes. Operates directly on the contract's used-digest set.
    function verifica(mapping(bytes32 => bool) storage used, bytes32 d) internal view returns (bool) {
        return !used[d];
    }
}
