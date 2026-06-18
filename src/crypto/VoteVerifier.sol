// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VoteVerifier — the cryptographic core: digest + nonce tag + verifica()
/// @notice The on-chain digest of a vote is keccak256(abi.encodePacked(vote, nonce))
///         (the spec's `Keccak256(voto + nonce)`). The vote is a bytes32 option id,
///         the nonce is the voter's secret string. Nonce uniqueness is enforced on a
///         separate, VOTE-INDEPENDENT commitment `nonceTag = keccak256(nonce)`, so a
///         reused nonce is rejected regardless of the chosen vote, while the digest
///         keeps the vote hidden until reveal.
library VoteVerifier {
    /// @notice digest = keccak256(voto + nonce). Hides the vote until reveal.
    function digest(bytes32 vote, string memory nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(vote, nonce));
    }

    /// @notice nonceTag = keccak256(nonce): a commitment to the nonce alone, used to
    ///         detect a reused nonce WITHOUT knowing the vote (so "same nonce, any
    ///         vote" collides). Does not reveal the vote.
    function nonceTag(string memory nonce) internal pure returns (bytes32) {
        return keccak256(bytes(nonce));
    }

    /// @notice Does (vote, nonce) hash to the stored digest? (reveal / tally check)
    function matches(bytes32 vote, string memory nonce, bytes32 stored) internal pure returns (bool) {
        return digest(vote, nonce) == stored;
    }

    /// @notice verifica(): is `tag` still free in this referendum's nonce domain?
    /// @dev Returns true when the nonce tag is NEW (not yet used), i.e. the uniqueness
    ///      check passes. Operates directly on the contract's used-nonce set, so the
    ///      same nonce can never be committed twice — with the same OR a different vote.
    function verifica(mapping(bytes32 => bool) storage used, bytes32 tag) internal view returns (bool) {
        return !used[tag];
    }
}
