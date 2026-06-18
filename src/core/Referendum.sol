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
///  reveal(nonce) [phase 2 only] — ONLY the nonce: the contract tries each option with
///                    it and confirms the one whose keccak256(option,nonce) == lastDigest.
///                    A correct reveal LOCKS the ballot; a wrong nonce can be retried.
///  PHASE 3 CLOSED  — close() counts, per wallet, the confirmed vote (already validated).
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
        bool confirmed; // a CORRECT reveal happened (nonce matched an option) — then locked
        bytes32 vote; // option found at confirmation (deduced from the nonce)
        string nonce; // confirmed nonce
    }
    mapping(address => Ballot) public ballots; // wallet k_i => ballot
    mapping(address => uint32) public revisions; // wallet k_i => (re)cast count
    mapping(bytes32 => bool) public usedNonce; // nonce domain: keccak(nonce) => used (verifica uniqueness)
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
            if (!b.confirmed) continue; // solo i voti confermati (nonce corretto) contano
            tally[b.vote] += 1; // b.vote è già un'opzione valida, dedotta al reveal
            ++valid;
        }
        finalized = true;
        phase = Phase.Closed;
        emit PhaseChanged(Phase.Closed);
        emit Finalized(valid, committedCount - valid); // nulli = committati ma non confermati
    }

    // -------------------------------------------------------------------- voter
    /// @notice PHASE 1: publish a hiding digest of your vote (geofenced + unique).
    /// @param d        keccak256(vote, nonce) — hides the vote until reveal.
    /// @param nonceTag keccak256(nonce) — vote-independent nonce commitment. Uniqueness
    ///                 is checked on this, so a reused nonce is rejected with the same
    ///                 OR a different vote. The frontend computes both client-side.
    function commit(bytes32 d, bytes32 nonceTag) external override {
        if (phase != Phase.Voting) revert Errors.VotingNotOpen();
        // separation of powers: a government cannot vote in its own jurisdiction
        if (router.isGovernment(msg.sender, jurisdiction)) revert Errors.GovernmentCannotVote();
        // identity is per-referendum: must have a (fake) SPID identity for THIS referendum
        if (!router.canVote(address(this), msg.sender, jurisdiction)) {
            if (!router.isAuthorized(address(this), msg.sender)) revert Errors.WalletNotAuthorized();
            revert Errors.OutOfJurisdiction();
        }
        if (!VoteVerifier.verifica(usedNonce, nonceTag)) revert Errors.NonceGiaUtilizzato();
        usedNonce[nonceTag] = true;
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

    /// @notice PHASE 2 (Tally) only: reveal with ONLY the nonce. The contract tries each
    ///         option with the committed nonce and finds the one whose digest matches
    ///         (reusing VoteVerifier.matches). A correct reveal LOCKS the ballot; a wrong
    ///         nonce (no option matches) confirms nothing and can be retried.
    function reveal(string calldata nonce) external override {
        if (phase != Phase.Tally) revert Errors.RevealClosed();
        Ballot storage b = ballots[msg.sender];
        if (!b.committed) revert Errors.NoVote();
        if (b.confirmed) revert Errors.AlreadyRevealed();
        for (uint256 i; i < options.length; ++i) {
            if (VoteVerifier.matches(options[i], nonce, b.lastDigest)) {
                b.confirmed = true;
                b.vote = options[i];
                b.nonce = nonce;
                revealedCount++;
                emit Revealed(msg.sender, options[i], nonce, true);
                return;
            }
        }
        // nessuna opzione combacia: nonce errato → non confermato, si può ritentare
        emit Revealed(msg.sender, bytes32(0), nonce, false);
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
