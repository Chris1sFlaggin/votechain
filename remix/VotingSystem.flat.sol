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
    error AlreadyRevealed(); // a correct reveal already locked this ballot

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
    error BelowMinVotes(); // il governo può esprimersi solo sui sondaggi che hanno superato il minimo
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
    function getOptions() external view returns (bytes32[] memory); // unique option ids
    function getLabels() external view returns (string[] memory); // human labels (parallel)
    function getVoters() external view returns (address[] memory);
    function result(bytes32 option) external view returns (uint256);

    // voter actions (PHASE 1 / 2)
    function commit(bytes32 digest, bytes32 nonceTag) external; // PHASE 1
    function reveal(string calldata nonce) external; // PHASE 2 — solo il nonce; il voto è dedotto

    // government actions
    function setPhase(Phase p) external; // Setup/Voting/Tally
    function close() external; // PHASE 3 (finalise)
}

// src/crypto/VoteVerifier.sol

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
///         The authorisation is created PER REFERENDUM: a (fake) SPID identity is
///         bound to the pair (referendum, wallet). The same wallet must create a
///         FRESH identity for each referendum it wants to vote in, and an identity
///         created for one referendum never authorises another one.
///         NO personal data reaches the chain — not even a pseudonym: only the
///         chosen jurisdiction is stored. Name, surname never
///         leave the client. Governments are registered per jurisdiction by the
///         ADMIN. Geofencing is enforced on-chain via canVote()/isGovernment().
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

    // (referendum, k_i) => authorisation — one (fake) SPID identity per referendum
    mapping(address => mapping(address => Wallet)) private _wallets;
    // a government may oversee one or more jurisdictions
    mapping(address => mapping(bytes32 => bool)) private _govFor; // gov => keccak(jurisdiction)
    mapping(address => bool) private _isAuthority; // gov di almeno una giurisdizione (per PollHub)

    event GovernmentRegistered(address indexed government, string jurisdiction);
    event WalletAuthorized(address indexed referendum, address indexed wallet, string jurisdiction);

    constructor() Roles(msg.sender) {
        _grant(ORACLE, msg.sender); // deployer doubles as the simulated SPID oracle
    }

    // ------------------------------------------------------------- admin (setup)
    /// @notice Register a government for a jurisdiction (may create referenda there).
    ///         Can be called multiple times to grant several jurisdictions.
    function registerGovernment(address government, string calldata jurisdiction) external onlyRole(ADMIN) {
        _govFor[government][keccak256(bytes(jurisdiction))] = true;
        _isAuthority[government] = true;
        emit GovernmentRegistered(government, jurisdiction);
    }

    // ------------------------------------------------- simulated SPID (static-site)
    /// @notice SIMULATED SPID login: the caller's wallet k_i self-enrols a fresh
    ///         identity FOR A SPECIFIC referendum, declaring a jurisdiction. NO
    ///         identity data is stored on-chain — not even a pseudonym: only the
    ///         chosen jurisdiction, bound to (referendum, wallet). The same wallet
    ///         must repeat this for every referendum; an identity does not carry over.
    ///         Callable directly from a static frontend with no backend.
    function simulatedSpidLogin(address referendum, string calldata jurisdiction) external {
        _wallets[referendum][msg.sender] = Wallet(true, jurisdiction);
        emit WalletAuthorized(referendum, msg.sender, jurisdiction);
    }

    // -------------------------------------------------------------- views (reads)
    function isAuthorized(address referendum, address wallet) external view returns (bool) {
        return _wallets[referendum][wallet].authorized;
    }

    function jurisdictionOf(address referendum, address wallet) external view returns (string memory) {
        return _wallets[referendum][wallet].jurisdiction;
    }

    /// @notice Geofencing: can `wallet` vote in `referendum` of `refJurisdiction`?
    ///         True only if it created a (fake) SPID identity for THAT referendum
    ///         in the matching jurisdiction.
    function canVote(address referendum, address wallet, string calldata refJurisdiction) external view returns (bool) {
        Wallet memory w = _wallets[referendum][wallet];
        return w.authorized && _eq(w.jurisdiction, refJurisdiction);
    }

    function isGovernment(address government, string calldata jurisdiction) external view returns (bool) {
        return _govFor[government][keccak256(bytes(jurisdiction))];
    }

    /// @notice È un governo di almeno una giurisdizione? (usato da PollHub per l'endorsement)
    function isAuthority(address who) external view returns (bool) {
        return _isAuthority[who];
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

// src/social/PollHub.sol

/// @title PollHub — raccolta firme social (petizioni).
/// @notice Chiunque crea una raccolta firme depositando una **cauzione** (stake anti-spam).
///         I cittadini firmano una sola volta (autenticazione via wallet).
///         Nessun voto su opzioni: è una petizione unica (sì/firma).
///         Se si superano **MIN_SIGNATURES** (5 per PoC), la raccolta diventa "approvabile"
///         dal governo. Il governo vede DUE liste:
///           1. Tutte le raccolte firme (anche sotto soglia)
///           2. Raccolte firme con ≥ MIN_SIGNATURES → può approvare o respingere.
///         Se approvata, il creatore riprende la cauzione; se respinta, la cauzione resta bloccata.
///         Nessuna identità/SPID/giurisdizione: parte aperta e social.
contract PollHub {
    uint64 public constant MIN_SIGNATURES = 5; // soglia minima firme per essere approvabile (PoC)

    struct Petition {
        address creator;
        string title;
        string description;
        uint128 stake; // cauzione del creatore (wei)
        uint64 signatureCount;
        bool approved; // true = approvata, false = respinta
        bool decided; // true se il governo ha deciso (approvato o respinto)
        bool claimed; // true se la cauzione è stata reclamata (solo se approvata)
    }

    /// @notice Decisione del governo su una raccolta firme.
    struct GovDecision {
        bool decided;
        bool approved;
        address by;
    }

    Petition[] private _petitions; // petitionId = indice
    mapping(uint256 => mapping(address => bool)) public hasSigned; // petitionId => firmatario => bool
    mapping(uint256 => GovDecision) private _govDecisions; // petitionId => decisione governo

    SPIDWalletRouter public immutable router; // per sapere chi è "governo" (isAuthority)

    event PetitionCreated(uint256 indexed id, address indexed creator, string title, uint128 stake);
    event Signed(uint256 indexed id, address indexed signer, uint64 totalSignatures);
    event PetitionDecided(uint256 indexed id, address indexed government, bool approved);
    event StakeClaimed(uint256 indexed id, address indexed creator, uint128 amount);

    constructor(SPIDWalletRouter _router) {
        router = _router;
    }

    // ------------------------------------------------------------ GOVERNO
    /// @notice Il GOVERNO (qualsiasi giurisdizione) approva o respinge una raccolta firme
    ///         che ha raggiunto MIN_SIGNATURES. È una transazione on-chain; può cambiare idea
    ///         (l'ultima decide) finché non viene reclamata la cauzione.
    ///         Gli utenti normali NON possono (lo impedisce la UI, ma qui è on-chain).
    function decide(uint256 id, bool approve) external {
        Petition storage p = _petitions[id];
        if (p.creator == address(0)) revert Errors.BadPoll();
        if (!router.isAuthority(msg.sender)) revert Errors.NotGovernment();
        if (p.signatureCount < MIN_SIGNATURES) revert Errors.BelowMinVotes(); // riutilizzo errore: "sotto soglia minima"

        _govDecisions[id] = GovDecision(true, approve, msg.sender);
        p.approved = approve;
        p.decided = true;
        emit PetitionDecided(id, msg.sender, approve);
    }

    /// @notice Decisione del governo su una raccolta firme (se presente).
    function decision(uint256 id) external view returns (bool decided, bool approved, address by) {
        GovDecision storage g = _govDecisions[id];
        return (g.decided, g.approved, g.by);
    }

    // ------------------------------------------------------------ CITTADINI / CREATORI
    /// @notice Crea una raccolta firme depositando la cauzione (msg.value).
    ///         Non servono opzioni: è una petizione unica (si firma o no).
    function createPetition(string calldata title, string calldata description) external payable returns (uint256 id) {
        if (bytes(title).length == 0 || bytes(description).length == 0 || msg.value == 0) revert Errors.BadPoll();
        id = _petitions.length;
        Petition storage p = _petitions.push();
        p.creator = msg.sender;
        p.title = title;
        p.description = description;
        p.stake = uint128(msg.value);
        emit PetitionCreated(id, msg.sender, title, p.stake);
    }

    /// @notice Firma una raccolta firme (una sola volta per indirizzo).
    ///         Non ci sono opzioni: la firma è unica per petizione.
    function sign(uint256 id) external {
        Petition storage p = _petitions[id];
        if (p.creator == address(0)) revert Errors.BadPoll();
        if (hasSigned[id][msg.sender]) revert Errors.AlreadyVoted(); // riutilizzo: "già firmato"
        if (p.decided) revert Errors.PollNotWon(); // riutilizzo: "petizione già decisa, non si può più firmare"

        hasSigned[id][msg.sender] = true;
        p.signatureCount += 1;
        emit Signed(id, msg.sender, p.signatureCount);
    }

    /// @notice Il creatore riprende la cauzione SE la raccolta è stata APPROVATA dal governo.
    function claim(uint256 id) external {
        Petition storage p = _petitions[id];
        if (msg.sender != p.creator) revert Errors.NotCreator();
        if (!p.decided) revert Errors.PollNotWon(); // non ancora decisa
        if (!p.approved) revert Errors.PollNotWon(); // respinta
        if (p.claimed) revert Errors.AlreadyClaimed();
        p.claimed = true; // checks-effects-interactions
        uint128 amt = p.stake;
        (bool ok,) = payable(p.creator).call{value: amt}("");
        require(ok, "refund failed");
        emit StakeClaimed(id, p.creator, amt);
    }

    // ------------------------------------------------------------ VIEWS
    function petitionsCount() external view returns (uint256) {
        return _petitions.length;
    }

    function getPetition(uint256 id)
        external
        view
        returns (
            address creator,
            string memory title,
            string memory description,
            uint128 stake,
            uint64 signatureCount,
            bool approved,
            bool decided,
            bool claimed
        )
    {
        Petition storage p = _petitions[id];
        return (p.creator, p.title, p.description, p.stake, p.signatureCount, p.approved, p.decided, p.claimed);
    }

    /// @notice Verifica se un indirizzo ha firmato una petizione.
    function hasSignedPetition(uint256 id, address signer) external view returns (bool) {
        return hasSigned[id][signer];
    }

    /// @notice Restituisce l'elenco dei firmatari (per trasparenza, gas permitting).
    ///         Nota: per petizioni con molti firmatari può costare gas.
    function getSigners(
        uint256 /* id */
    )
        external
        pure
        returns (address[] memory)
    {
        // Non implementato on-chain per efficienza; il frontend può indicizzare dagli eventi Signed.
        return new address[](0);
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

    bytes32[] public options; // UNIQUE option ids (two equal labels still get distinct ids)
    string[] private _labels; // human labels, parallel to options (may repeat)
    mapping(bytes32 => uint256) public tally; // option id => confirmed votes (set at close)

    struct Ballot {
        bytes32 lastDigest; // only the last digest counts
        bool committed;
        bool confirmed; // a CORRECT reveal happened (nonce matched an option) — then locked
        bytes32 vote; // option found at confirmation (deduced from the nonce)
        string nonce; // confirmed nonce
    }
    mapping(address => Ballot) public ballots; // wallet k_i => ballot
    mapping(address => uint32) public revisions; // wallet k_i => (re)cast count
    // nonce domain PER WALLET: voter => keccak(nonce) => used. A reused nonce is rejected
    // only against the SAME voter's previous commits (not against other users).
    mapping(address => mapping(bytes32 => bool)) public usedNonce;
    address[] public voters; // participating wallets, for the tally

    uint256 public committedCount;
    uint256 public revealedCount;

    event Committed(address indexed voter, bytes32 digest, uint32 revision);
    event Revealed(address indexed voter, string vote, string nonce, bool matches);
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
        string[] memory optionLabels
    ) {
        _government = gov;
        router = _router;
        title = _title;
        jurisdiction = _jurisdiction;
        // each option gets a UNIQUE id even if two labels are identical (e.g. omonymous
        // candidates): id = keccak256(this, index, label). The label is kept for display.
        for (uint256 i; i < optionLabels.length; ++i) {
            _labels.push(optionLabels[i]);
            options.push(keccak256(abi.encodePacked(address(this), i, optionLabels[i])));
        }
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
    ///                 is checked per-wallet on this, so a reused nonce is rejected with
    ///                 the same OR a different vote, but only against the caller's own
    ///                 commits (other voters may reuse it). Frontend computes both.
    function commit(bytes32 d, bytes32 nonceTag) external override {
        if (phase != Phase.Voting) revert Errors.VotingNotOpen();
        // separation of powers: a government cannot vote in its own jurisdiction
        if (router.isGovernment(msg.sender, jurisdiction)) revert Errors.GovernmentCannotVote();
        // identity is per-referendum: must have a (fake) SPID identity for THIS referendum
        if (!router.canVote(address(this), msg.sender, jurisdiction)) {
            if (!router.isAuthorized(address(this), msg.sender)) revert Errors.WalletNotAuthorized();
            revert Errors.OutOfJurisdiction();
        }
        if (!VoteVerifier.verifica(usedNonce[msg.sender], nonceTag)) revert Errors.NonceGiaUtilizzato();
        usedNonce[msg.sender][nonceTag] = true;
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
                emit Revealed(msg.sender, _labels[i], nonce, true); // label leggibile nell'evento
                return;
            }
        }
        // nessuna opzione combacia: nonce errato → non confermato, si può ritentare
        emit Revealed(msg.sender, "", nonce, false);
    }

    // -------------------------------------------------------------------- views
    function getOptions() external view override returns (bytes32[] memory) {
        return options;
    }

    /// @notice Human labels parallel to getOptions() (display only; may repeat).
    function getLabels() external view override returns (string[] memory) {
        return _labels;
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

    function createReferendum(string calldata title, string calldata jurisdiction, string[] calldata optionLabels)
        external
        returns (address)
    {
        if (!router.isGovernment(msg.sender, jurisdiction)) revert Errors.NotGovernment();
        if (optionLabels.length < 2) revert Errors.EmptyOptions();

        Referendum r = new Referendum(msg.sender, router, title, jurisdiction, optionLabels);
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
    address public constant EXTRA_GOV2 = 0xE6bbD7Ee72Fe05B50e15416B0E03A80C43f3F861;

    event SystemReady(address router, address factory, address pollHub, address government);

    constructor() {
        router = new SPIDWalletRouter(); // this contract becomes ADMIN + ORACLE
        factory = new GovFactory(router);
        pollHub = new PollHub(router); // parte social: sondaggi + endorsement del governo

        address human = tx.origin; // the EOA deploying via Remix/MetaMask
        router.grantRole(router.ADMIN(), human);
        router.grantRole(router.ORACLE(), human);
        router.registerGovernment(human, "Italia");
        router.registerGovernment(human, "San Marino");

        // extra fixed government wallets (Italia + San Marino)
        router.registerGovernment(EXTRA_GOV, "Italia");
        router.registerGovernment(EXTRA_GOV, "San Marino");
        router.registerGovernment(EXTRA_GOV2, "Italia");
        router.registerGovernment(EXTRA_GOV2, "San Marino");

        emit SystemReady(address(router), address(factory), address(pollHub), human);
    }

    /// @notice Convenience read for the frontend: core addresses in one call.
    function addresses() external view returns (address routerAddr, address factoryAddr, address pollHubAddr) {
        return (address(router), address(factory), address(pollHub));
    }
}

