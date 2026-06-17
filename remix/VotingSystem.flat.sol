// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// src/utils/Errors.sol

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

// src/interfaces/IReferendum.sol

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
    function commit(bytes32 digest) external; // PHASE 1
    function reveal(bytes32 vote, string calldata nonce) external; // PHASE 1 or 2

    // government actions
    function setPhase(Phase p) external; // Setup/Voting/Tally
    function close() external; // PHASE 3 (finalise)
}

// src/crypto/VoteVerifier.sol

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

// src/social/PollHub.sol

/// @title PollHub — sondaggi "social" aperti a tutti (lato non istituzionale).
/// @notice Chiunque crea un sondaggio depositando una **cauzione** (stake). Chiunque
///         vota una volta sola. Il sondaggio "vince" quando il risultato è
///         **statisticamente significativo**: la soglia NON è scelta dal creatore ma
///         calcolata dal contratto secondo l'errore standard.
///
///         Regola (≈95% di confidenza, 2 errori standard, su n = voti totali):
///             vince  ⇔  n ≥ MIN_VOTES  e  (primo − secondo) > 2·√n
///         Per evitare la radice on-chain si confronta al quadrato:
///             (primo − secondo)² > 4·n
///
///         Quando vince, il creatore riprende la cauzione (claim). Se non raggiunge
///         mai la significatività, la cauzione resta bloccata (anti-spam). Nessuna
///         identità/SPID/giurisdizione: parte aperta e social.
contract PollHub {
    uint64 public constant MIN_VOTES = 5; // campione minimo perché un test sia sensato

    struct Poll {
        address creator;
        string question;
        bytes32[] options;
        uint128 stake; // cauzione del creatore (wei)
        uint64 totalVotes;
        bool won;
        bool claimed;
    }

    Poll[] private _polls; // pollId = indice
    mapping(uint256 => mapping(bytes32 => uint256)) public votesOf; // pollId => opzione => conteggio
    mapping(uint256 => mapping(address => bool)) public hasVoted; // pollId => votante => bool

    event PollCreated(uint256 indexed id, address indexed creator, string question, uint128 stake);
    event Voted(uint256 indexed id, address indexed voter, bytes32 option, uint64 totalVotes);
    event PollWon(uint256 indexed id);
    event StakeClaimed(uint256 indexed id, address indexed creator, uint128 amount);

    /// @notice Crea un sondaggio depositando la cauzione (msg.value). Nessuna soglia.
    function createPoll(string calldata question, bytes32[] calldata options) external payable returns (uint256 id) {
        if (options.length < 2 || msg.value == 0 || bytes(question).length == 0) revert Errors.BadPoll();
        id = _polls.length;
        Poll storage p = _polls.push();
        p.creator = msg.sender;
        p.question = question;
        p.options = options;
        p.stake = uint128(msg.value);
        emit PollCreated(id, msg.sender, question, p.stake);
    }

    /// @notice Vota un'opzione (una sola volta per indirizzo).
    function vote(uint256 id, bytes32 option) external {
        Poll storage p = _polls[id];
        if (p.creator == address(0)) revert Errors.BadPoll();
        if (hasVoted[id][msg.sender]) revert Errors.AlreadyVoted();
        if (!_isOption(p, option)) revert Errors.UnknownOption();

        hasVoted[id][msg.sender] = true;
        votesOf[id][option] += 1;
        p.totalVotes += 1;
        emit Voted(id, msg.sender, option, p.totalVotes);

        if (!p.won) {
            (uint256 top, uint256 second) = _topTwo(id, p);
            if (_significant(top, second, p.totalVotes)) {
                p.won = true;
                emit PollWon(id);
            }
        }
    }

    /// @notice Il creatore riprende la cauzione SE il sondaggio ha vinto.
    function claim(uint256 id) external {
        Poll storage p = _polls[id];
        if (msg.sender != p.creator) revert Errors.NotCreator();
        if (!p.won) revert Errors.PollNotWon();
        if (p.claimed) revert Errors.AlreadyClaimed();
        p.claimed = true; // checks-effects-interactions
        uint128 amt = p.stake;
        (bool ok,) = payable(p.creator).call{value: amt}("");
        require(ok, "refund failed");
        emit StakeClaimed(id, p.creator, amt);
    }

    // --------------------------------------------------------------- math (win)
    /// @dev Significatività statistica: n ≥ MIN_VOTES e (top−second) > 2·√n  ⇔  (top−second)² > 4·n.
    function _significant(uint256 top, uint256 second, uint64 total) internal pure returns (bool) {
        if (total < MIN_VOTES) return false;
        uint256 lead = top - second;
        return lead * lead > 4 * uint256(total);
    }

    function _topTwo(uint256 id, Poll storage p) internal view returns (uint256 top, uint256 second) {
        for (uint256 i; i < p.options.length; ++i) {
            uint256 c = votesOf[id][p.options[i]];
            if (c >= top) {
                second = top;
                top = c;
            } else if (c > second) {
                second = c;
            }
        }
    }

    // -------------------------------------------------------------------- views
    function pollsCount() external view returns (uint256) {
        return _polls.length;
    }

    function getPoll(uint256 id)
        external
        view
        returns (
            address creator,
            string memory question,
            bytes32[] memory options,
            uint128 stake,
            uint64 totalVotes,
            bool won,
            bool claimed
        )
    {
        Poll storage p = _polls[id];
        return (p.creator, p.question, p.options, p.stake, p.totalVotes, p.won, p.claimed);
    }

    function optionVotes(uint256 id, bytes32 option) external view returns (uint256) {
        return votesOf[id][option];
    }

    /// @notice Stato per la UI: voti primo/secondo, totale, e se ha vinto.
    function standing(uint256 id) external view returns (uint256 top, uint256 second, uint64 total, bool won) {
        Poll storage p = _polls[id];
        (top, second) = _topTwo(id, p);
        return (top, second, p.totalVotes, p.won);
    }

    function _isOption(Poll storage p, bytes32 o) internal view returns (bool) {
        for (uint256 i; i < p.options.length; ++i) {
            if (p.options[i] == o) return true;
        }
        return false;
    }
}

// src/auth/Roles.sol

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

// src/auth/SPIDWalletRouter.sol

/// @title SPIDWalletRouter — (simulated) SPID authorisation + electoral geofencing.
/// @notice On-chain projection of the off-chain SPID step. A real accredited IdP
///         cannot run on-chain; here a citizen self-enrols from their own wallet k_i
///         (e.g. MetaMask) declaring a jurisdiction — a pure PoC of the flow.
///         NO personal data reaches the chain — not even a pseudonym: only the
///         chosen jurisdiction is stored, bound to the wallet k_i. Name, surname and
///         codice fiscale never leave the client. Governments are registered per
///         jurisdiction by the ADMIN. Geofencing is enforced on-chain via
///         canVote()/isGovernment().
///
/// @dev SECURITY (PoC): simulatedSpidLogin() trusts the caller — anyone can enrol any
///      jurisdiction. In production an accredited IdP + off-chain oracle
///      would issue the authorisation (binding the jurisdiction to the verified
///      identity) before it is written here.
contract SPIDWalletRouter is Roles {
    struct Wallet {
        bool authorized;
        string jurisdiction;
    }

    mapping(address => Wallet) private _wallets; // k_i => authorisation
    // a government may oversee one or more jurisdictions
    mapping(address => mapping(bytes32 => bool)) private _govFor; // gov => keccak(jurisdiction)

    event GovernmentRegistered(address indexed government, string jurisdiction);
    event WalletAuthorized(address indexed wallet, string jurisdiction);

    constructor() Roles(msg.sender) {
        _grant(ORACLE, msg.sender); // deployer doubles as the simulated SPID oracle
    }

    // ------------------------------------------------------------- admin (setup)
    /// @notice Register a government for a jurisdiction (may create referenda there).
    ///         Can be called multiple times to grant several jurisdictions.
    function registerGovernment(address government, string calldata jurisdiction) external onlyRole(ADMIN) {
        _govFor[government][keccak256(bytes(jurisdiction))] = true;
        emit GovernmentRegistered(government, jurisdiction);
    }

    // ------------------------------------------------- simulated SPID (static-site)
    /// @notice SIMULATED SPID login: the caller's wallet k_i self-enrols for a
    ///         jurisdiction. NO identity data is stored on-chain — not even a
    ///         pseudonym: only the chosen jurisdiction, bound to the wallet.
    ///         Callable directly from a static frontend with no backend.
    function simulatedSpidLogin(string calldata jurisdiction) external {
        _wallets[msg.sender] = Wallet(true, jurisdiction);
        emit WalletAuthorized(msg.sender, jurisdiction);
    }

    // -------------------------------------------------------------- views (reads)
    function isAuthorized(address wallet) external view returns (bool) {
        return _wallets[wallet].authorized;
    }

    function jurisdictionOf(address wallet) external view returns (string memory) {
        return _wallets[wallet].jurisdiction;
    }

    /// @notice Geofencing: may `wallet` vote in a referendum of `refJurisdiction`?
    function canVote(address wallet, string calldata refJurisdiction) external view returns (bool) {
        Wallet memory w = _wallets[wallet];
        return w.authorized && _eq(w.jurisdiction, refJurisdiction);
    }

    function isGovernment(address government, string calldata jurisdiction) external view returns (bool) {
        return _govFor[government][keccak256(bytes(jurisdiction))];
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

// src/core/Referendum.sol

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
        if (!router.canVote(msg.sender, jurisdiction)) {
            if (!router.isAuthorized(msg.sender)) revert Errors.WalletNotAuthorized();
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

// src/core/GovFactory.sol

/// @title GovFactory — lets a registered government deploy new Referendum contracts.
/// @notice The government calls createReferendum() and a dedicated Referendum `i`
///         contract is deployed via `new` (on-chain factory). A government may only
///         create referenda in its OWN jurisdiction (creation-side geofencing,
///         enforced through the SPIDWalletRouter).
contract GovFactory {
    SPIDWalletRouter public immutable router;
    address[] private _referenda;

    event ReferendumCreated(address indexed referendum, address indexed government, string jurisdiction, string title);

    constructor(SPIDWalletRouter _router) {
        router = _router;
    }

    function createReferendum(string calldata title, string calldata jurisdiction, bytes32[] calldata options)
        external
        returns (address)
    {
        if (!router.isGovernment(msg.sender, jurisdiction)) revert Errors.NotGovernment();
        if (options.length < 2) revert Errors.EmptyOptions();

        Referendum r = new Referendum(msg.sender, router, title, jurisdiction, options);
        _referenda.push(address(r));
        emit ReferendumCreated(address(r), msg.sender, jurisdiction, title);
        return address(r);
    }

    function getReferenda() external view returns (address[] memory) {
        return _referenda;
    }

    function count() external view returns (uint256) {
        return _referenda.length;
    }
}

// src/SystemBootstrap.sol

/// @title SystemBootstrap — one-click wiring of the whole system (Remix friendly).
/// @notice Deploy THIS single contract and the system is ready:
///   * deploys SPIDWalletRouter + GovFactory;
///   * makes the deployer (your MetaMask/Remix account) ADMIN + ORACLE and a
///     government for both "Italia" and "San Marino".
/// Then create referenda from your own account via the Factory (so you own/govern
/// them). Voters self-enrol a fake SPID identity straight from the dApp — nothing
/// is pre-seeded, no personal data is stored.
contract SystemBootstrap {
    SPIDWalletRouter public router;
    GovFactory public factory;
    PollHub public pollHub;

    /// @notice Extra government wallet pre-registered at deploy, besides the deployer
    ///         (so it can issue/manage referenda from the dApp's government panel).
    address public constant EXTRA_GOV = 0x22a2bc6E24FBa136023A126560E2D2490A834B54;

    event SystemReady(address router, address factory, address pollHub, address government);

    constructor() {
        router = new SPIDWalletRouter(); // this contract becomes ADMIN + ORACLE
        factory = new GovFactory(router);
        pollHub = new PollHub(); // parte social: sondaggi aperti a tutti

        address human = tx.origin; // the EOA deploying via Remix/MetaMask
        router.grantRole(router.ADMIN(), human);
        router.grantRole(router.ORACLE(), human);
        router.registerGovernment(human, "Italia");
        router.registerGovernment(human, "San Marino");

        // a second, fixed government wallet (Italia + San Marino)
        router.registerGovernment(EXTRA_GOV, "Italia");
        router.registerGovernment(EXTRA_GOV, "San Marino");

        emit SystemReady(address(router), address(factory), address(pollHub), human);
    }

    /// @notice Convenience read for the frontend: core addresses in one call.
    function addresses() external view returns (address routerAddr, address factoryAddr, address pollHubAddr) {
        return (address(router), address(factory), address(pollHub));
    }
}
