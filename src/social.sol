// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// PollHub — raccolta firme social (petizioni). Governo = chi fa il deploy.
// Nessun SPID/router: il deployer è il governo che approva/respinge le petizioni
// che superano MIN_SIGNATURES. Chiunque crea una raccolta depositando una cauzione
// (anti-spam) e chiunque firma una sola volta col proprio wallet. Se approvata, il
// creatore riprende la cauzione; se respinta, resta bloccata. File autosufficiente.

// ----------------------------------------------------------------- errori (gas-efficient)
error BadPoll();
error AlreadyVoted(); // riuso: "già firmato"
error NotCreator();
error PollNotWon();
error AlreadyClaimed();
error BelowMinVotes(); // sotto la soglia minima di firme
error NotGovernment();
error AlreadyDecided(); // decide chiamata due volte sulla stessa petizione
error NotClosed(); // claim su un round non ancora chiuso

contract PollHub {
    uint64 public constant MIN_SIGNATURES = 5; // soglia minima firme per essere approvabile (PoC)

    address public immutable government; // chi ha fatto il deploy

    uint256 public round; // round APERTO corrente (parte da 0)
    mapping(uint256 => uint256) public forfeitedOf; // round => somma stake delle respinte
    mapping(uint256 => uint256) public approvedStakeOf; // round => somma stake delle approvate

    struct Petition {
        address creator;
        string title;
        string description;
        uint128 stake; // cauzione del creatore (wei)
        uint64 signatureCount;
        bool approved; // true = approvata, false = respinta
        bool decided; // true se il governo ha deciso
        bool claimed; // true se la cauzione è stata reclamata
        uint256 decidedRound; // round in cui il governo ha deciso la petizione
    }

    struct GovDecision {
        bool decided;
        bool approved;
        address by;
    }

    Petition[] private _petitions; // petitionId = indice
    mapping(uint256 => mapping(address => bool)) public hasSigned; // id => firmatario => bool
    mapping(uint256 => GovDecision) private _govDecisions; // id => decisione governo

    event PetitionCreated(uint256 indexed id, address indexed creator, string title, uint128 stake);
    event Signed(uint256 indexed id, address indexed signer, uint64 totalSignatures);
    event PetitionDecided(uint256 indexed id, address indexed government, bool approved);
    event StakeClaimed(uint256 indexed id, address indexed creator, uint256 stake, uint256 roi);
    event PeriodClosed(uint256 indexed round, uint256 forfeited, uint256 approvedStake);

    modifier onlyGov() {
        if (msg.sender != government) revert NotGovernment();
        _;
    }

    constructor() {
        government = msg.sender;
    }

    // ------------------------------------------------------------------------------ GOVERNO
    /// @notice Il GOVERNO (deployer) approva o respinge una raccolta che ha raggiunto
    ///         MIN_SIGNATURES. Può cambiare idea (l'ultima decide) finché non è reclamata.
    function decide(uint256 id, bool approve) external onlyGov {
        Petition storage p = _petitions[id];
        if (p.creator == address(0)) revert BadPoll();
        if (p.signatureCount < MIN_SIGNATURES) revert BelowMinVotes();
        if (p.decided) revert AlreadyDecided(); // finalita': niente piu' cambio di idea
        _govDecisions[id] = GovDecision(true, approve, msg.sender);
        p.approved = approve;
        p.decided = true;
        p.decidedRound = round; // si settla nel round corrente
        if (approve) approvedStakeOf[round] += p.stake;
        else forfeitedOf[round] += p.stake; // respinta: lo stake alimenta il montepremi del round
        emit PetitionDecided(id, msg.sender, approve);
    }

    /// @notice Il GOVERNO chiude il round corrente: forfeitedOf/approvedStakeOf diventano
    ///         definitivi e gli approvati di quel round possono reclamare. Ne apre subito uno nuovo.
    function closePeriod() external onlyGov {
        emit PeriodClosed(round, forfeitedOf[round], approvedStakeOf[round]);
        round += 1; // il round appena chiuso e' ora immutabile e reclamabile
    }

    function decision(uint256 id) external view returns (bool decided, bool approved, address by) {
        GovDecision storage g = _govDecisions[id];
        return (g.decided, g.approved, g.by);
    }

    // ------------------------------------------------------------------ CITTADINI / CREATORI
    /// @notice Crea una raccolta firme depositando la cauzione (msg.value).
    function createPetition(string calldata title, string calldata description) external payable returns (uint256 id) {
        if (bytes(title).length == 0 || bytes(description).length == 0 || msg.value == 0) revert BadPoll();
        id = _petitions.length;
        Petition storage p = _petitions.push();
        p.creator = msg.sender;
        p.title = title;
        p.description = description;
        p.stake = uint128(msg.value);
        emit PetitionCreated(id, msg.sender, title, p.stake);
    }

    /// @notice Firma una raccolta (una sola volta per indirizzo).
    function sign(uint256 id) external {
        Petition storage p = _petitions[id];
        if (p.creator == address(0)) revert BadPoll();
        if (hasSigned[id][msg.sender]) revert AlreadyVoted();
        if (p.decided) revert PollNotWon(); // già decisa: non si firma più
        hasSigned[id][msg.sender] = true;
        p.signatureCount += 1;
        emit Signed(id, msg.sender, p.signatureCount);
    }

    /// @notice Il creatore riprende la cauzione SE approvata dal governo.
    function claim(uint256 id) external {
        Petition storage p = _petitions[id];
        if (msg.sender != p.creator) revert NotCreator();
        if (!p.decided) revert PollNotWon();
        if (!p.approved) revert PollNotWon();
        if (p.decidedRound >= round) revert NotClosed(); // round del voto non ancora chiuso
        if (p.claimed) revert AlreadyClaimed();
        p.claimed = true; // checks-effects-interactions

        uint256 stakeAmt = uint256(p.stake);
        uint256 rr = p.decidedRound;
        // quota proporzionale del montepremi del round (moltiplica PRIMA di dividere)
        uint256 roi = approvedStakeOf[rr] == 0 ? 0 : (forfeitedOf[rr] * stakeAmt) / approvedStakeOf[rr];

        (bool ok,) = payable(p.creator).call{value: stakeAmt + roi}("");
        require(ok, "payout failed");
        emit StakeClaimed(id, p.creator, stakeAmt, roi);
    }

    // -------------------------------------------------------------------------------- VIEWS
    function petitionsCount() external view returns (uint256) {
        return _petitions.length;
    }

    function petitionRound(uint256 id) external view returns (uint256) {
        return _petitions[id].decidedRound;
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

    function hasSignedPetition(uint256 id, address signer) external view returns (bool) {
        return hasSigned[id][signer];
    }
}
