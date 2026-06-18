// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IReferendum — standard interface to interact with a single referendum.
/// @notice Used by the factory and by the (static) frontend to drive any referendum
///         contract regardless of its concrete implementation.
interface IReferendum {
    enum Phase {
        Setup,
        Voting,
        Tally,
        Closed
    }

    // metadata
    function title() external view returns (string memory);
    function jurisdiction() external view returns (string memory);
    function government() external view returns (address);
    function phase() external view returns (Phase);
    function finalized() external view returns (bool);
    function getOptions() external view returns (bytes32[] memory);
    function getVoters() external view returns (address[] memory);
    function result(bytes32 option) external view returns (uint256);

    // voter actions (PHASE 1 / 2)
    function commit(bytes32 digest, bytes32 nonceTag) external; // PHASE 1
    function reveal(string calldata nonce) external; // PHASE 2 — solo il nonce; il voto è dedotto

    // government actions
    function setPhase(Phase p) external; // Setup/Voting/Tally
    function close() external; // PHASE 3 (finalise)
}
