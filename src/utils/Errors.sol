// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Errors — custom errors shared across the voting system (gas-efficient).
library Errors {
    // access control
    error Unauthorized(bytes32 role);
    error NotGovernment();

    // SPID / geofencing (auth)
    error WalletNotAuthorized(); // wallet k_i never authorised via (simulated) SPID
    error OutOfJurisdiction(); // wallet authorised, but not for this referendum
    error GovernmentCannotVote(); // separation of powers: the authority cannot vote

    // commit / reveal (core)
    error NonceGiaUtilizzato(); // digest already present in the referendum domain
    error VotingNotOpen();
    error RevealClosed();
    error NoVote();

    // lifecycle
    error CloseOnlyFromTally();
    error AlreadyFinalized();
    error EmptyOptions();

    // social polls
    error BadPoll();
    error AlreadyVoted();
    error UnknownOption();
    error NotCreator();
    error PollNotWon();
    error AlreadyClaimed();
}
