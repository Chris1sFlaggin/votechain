// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IReferendum} from "../interfaces/IReferendum.sol";
import {SPIDWalletRouter} from "../auth/SPIDWalletRouter.sol";
import {VoteVerifier} from "../crypto/VoteVerifier.sol";
import {Errors} from "../utils/Errors.sol";

/// @title Referendum — a single referendum `i` over its three strict phases.
/// @notice Voters are identified by their wallet `k_i` (msg.sender), authorised and
///         geofenced through the SPIDWalletRouter. The vote stays hidden behind the
///         digest keccak256(vote, nonce) until reveal.
///
///  PHASE 1 VOTING  — commit(digest) only; verifica() rejects a digest already present
///                    (nonce uniqueness); re-voting allowed, only the last counts.
///                    NO reveal here, so no running tally exists before the spoglio.
///  PHASE 2 TALLY   — no new digests; reveal opens.
///  reveal(vote,nonce) [phase 2 only] — publishes the vote IN CLEAR in ANY case;
///                    the last reveal is kept; the `matches` flag is UX-only.
///  PHASE 3 CLOSED  — close() counts, per wallet, the last reveal iff
///                    keccak256(lastVote, lastNonce) == lastDigest.
contract Referendum is IReferendum {
    SPIDWalletRouter public immutable router;
    address private immutable _government;

    string public override title;
    string public override jurisdiction;
    Phase public override phase;
    bool public override finalized;

    bytes32[] public options;
    mapping(bytes32 => uint256) public tally; // option => confirmed votes (set at close)

    struct Ballot {
        bytes32 lastDigest; // only the last digest counts
        bool committed;
        bool revealed;
        bytes32 lastVote; // cleartext vote of the last reveal
        string lastNonce; // nonce of the last reveal
    }
    mapping(address => Ballot) public ballots; // wallet k_i => ballot
    mapping(address => uint32) public revisions; // wallet k_i => (re)cast count
    mapping(bytes32 => bool) public usedDigest; // digest domain (verifica uniqueness)
    address[] public voters; // participating wallets, for the tally

    uint256 public committedCount;
    uint256 public revealedCount;

    event Committed(address indexed voter, bytes32 digest, uint32 revision);
    event Revealed(address indexed voter, bytes32 vote, string nonce, bool matches);
    event PhaseChanged(Phase phase);
    event Finalized(uint256 valid, uint256 nullified);

    modifier onlyGov() {
        if (msg.sender != _government) revert Errors.NotGovernment();
        _;
    }

    constructor(
        address gov,
        SPIDWalletRouter _router,
        string memory _title,
        string memory _jurisdiction,
        bytes32[] memory _options
    ) {
        _government = gov;
        router = _router;
        title = _title;
        jurisdiction = _jurisdiction;
        options = _options;
        phase = Phase.Voting; // open immediately once issued
        emit PhaseChanged(phase);
    }

    function government() external view override returns (address) {
        return _government;
    }

    // -------------------------------------------------------------- government
    function setPhase(Phase p) external override onlyGov {
        if (p == Phase.Closed) revert Errors.CloseOnlyFromTally();
        if (finalized) revert Errors.AlreadyFinalized();
        phase = p;
        emit PhaseChanged(p);
    }

    /// @notice PHASE 3: close and compute the official tally on-chain.
    function close() external override onlyGov {
        if (phase != Phase.Tally) revert Errors.CloseOnlyFromTally();
        if (finalized) revert Errors.AlreadyFinalized();
        uint256 valid;
        for (uint256 i; i < voters.length; ++i) {
            Ballot storage b = ballots[voters[i]];
            if (!b.revealed) continue;
            if (VoteVerifier.matches(b.lastVote, b.lastNonce, b.lastDigest) && _isOption(b.lastVote)) {
                tally[b.lastVote] += 1;
                ++valid;
            }
        }
        finalized = true;
        phase = Phase.Closed;
        emit PhaseChanged(Phase.Closed);
        emit Finalized(valid, revealedCount - valid);
    }

    // -------------------------------------------------------------------- voter
    /// @notice PHASE 1: publish a hiding digest of your vote (geofenced + unique).
    function commit(bytes32 d) external override {
        if (phase != Phase.Voting) revert Errors.VotingNotOpen();
        // separation of powers: a government cannot vote in its own jurisdiction
        if (router.isGovernment(msg.sender, jurisdiction)) revert Errors.GovernmentCannotVote();
        // identity is per-referendum: must have a (fake) SPID identity for THIS referendum
        if (!router.canVote(address(this), msg.sender, jurisdiction)) {
            if (!router.isAuthorized(address(this), msg.sender)) revert Errors.WalletNotAuthorized();
            revert Errors.OutOfJurisdiction();
        }
        if (!VoteVerifier.verifica(usedDigest, d)) revert Errors.NonceGiaUtilizzato();
        usedDigest[d] = true;
        Ballot storage b = ballots[msg.sender];
        if (!b.committed) {
            b.committed = true;
            committedCount++;
            voters.push(msg.sender);
        }
        b.lastDigest = d;
        revisions[msg.sender]++;
        emit Committed(msg.sender, d, revisions[msg.sender]);
    }

    /// @notice PHASE 2 (Tally) only: reveal. Recorded IN CLEAR in ANY case; last reveal kept.
    function reveal(bytes32 vote, string calldata nonce) external override {
        if (phase != Phase.Tally) revert Errors.RevealClosed();
        Ballot storage b = ballots[msg.sender];
        if (!b.committed) revert Errors.NoVote();
        if (!b.revealed) {
            b.revealed = true;
            revealedCount++;
        }
        b.lastVote = vote;
        b.lastNonce = nonce;
        emit Revealed(msg.sender, vote, nonce, VoteVerifier.matches(vote, nonce, b.lastDigest));
    }

    // -------------------------------------------------------------------- views
    function getOptions() external view override returns (bytes32[] memory) {
        return options;
    }

    function getVoters() external view override returns (address[] memory) {
        return voters;
    }

    function result(bytes32 option) external view override returns (uint256) {
        return tally[option];
    }

    function votersCount() external view returns (uint256) {
        return voters.length;
    }

    function isOption(bytes32 o) external view returns (bool) {
        return _isOption(o);
    }

    function _isOption(bytes32 o) internal view returns (bool) {
        for (uint256 i; i < options.length; ++i) {
            if (options[i] == o) return true;
        }
        return false;
    }
}
