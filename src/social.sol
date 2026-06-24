// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// PollHub — raccolta firme social (petizioni). Governo = chi fa il deploy.
// Chiunque crea una raccolta depositando una cauzione (anti-spam) e chiunque firma
// una sola volta col proprio wallet, entro una finestra temporale fissa (POLL_TIMEOUT,
// uguale per ogni petizione). Allo scadere il creatore liquida la cauzione:
//   - firme >= MIN_SIGNATURES -> rimborso integrale al creatore;
//   - firme <  MIN_SIGNATURES -> penale anti-spam: 50% allo Stato (governo), 50% al creatore.
// Il governo puo' inoltre esprimere una valutazione istituzionale (decide) come segnale
// on-chain (approva/respinge), SENZA alcun effetto sulla cauzione. File autosufficiente.

// ----------------------------------------------------------------- errori (gas-efficient)
error BadPoll();
error AlreadyVoted(); // riuso: "già firmato"
error NotCreator();
error AlreadyClaimed();
error BelowMinVotes(); // sotto la soglia minima di firme (per decide)
error NotGovernment();
error AlreadyDecided(); // decide chiamata due volte sulla stessa petizione
error SigningClosed(); // firma dopo la scadenza della raccolta
error StillOpen(); // claim prima della scadenza della raccolta

contract PollHub {
    // Parametri di sistema (PoC): modificabili in un punto solo.
    uint64 public constant MIN_SIGNATURES = 5; // soglia firme per il rimborso integrale
    uint64 public constant POLL_TIMEOUT = 7 days; // durata raccolta, uguale per ogni petizione

    address public immutable government; // chi ha fatto il deploy = "Stato"

    struct Petition {
        // campi ordinati per impacchettamento: creator + 3 bool in uno slot,
        // stake + i due uint64 nel successivo; le stringhe dinamiche in coda.
        address creator;
        bool approved; // valutazione istituzionale (segnale; nessun effetto sui soldi)
        bool decided; // true se il governo ha espresso la valutazione
        bool claimed; // true se la cauzione è stata liquidata
        uint128 stake; // cauzione del creatore (wei)
        uint64 signatureCount;
        uint64 createdAt; // timestamp di creazione; scadenza = createdAt + POLL_TIMEOUT
        string title;
        string description;
    }

    Petition[] private _petitions; // petitionId = indice
    mapping(uint256 => mapping(address => bool)) public hasSigned; // id => firmatario => bool

    event PetitionCreated(uint256 indexed id, address indexed creator, string title, uint128 stake, uint64 deadline);
    event Signed(uint256 indexed id, address indexed signer, uint64 totalSignatures);
    event PetitionDecided(uint256 indexed id, address indexed government, bool approved);
    event StakeResolved(
        uint256 indexed id, address indexed creator, uint256 refunded, uint256 toState, bool reachedQuorum
    );

    modifier onlyGov() {
        if (msg.sender != government) revert NotGovernment();
        _;
    }

    constructor() {
        government = msg.sender;
    }

    // ------------------------------------------------------------------ CITTADINI / CREATORI
    /// @notice Crea una raccolta firme depositando la cauzione (msg.value). Parte subito la
    ///         finestra di firma, lunga POLL_TIMEOUT.
    /// @param title       Titolo della petizione.
    /// @param description Testo della petizione.
    /// @return id         Indice assegnato alla nuova petizione.
    function createPetition(string calldata title, string calldata description) external payable returns (uint256 id) {
        if (bytes(title).length == 0 || bytes(description).length == 0 || msg.value == 0) revert BadPoll();
        id = _petitions.length;
        Petition storage p = _petitions.push();
        p.creator = msg.sender;
        p.title = title;
        p.description = description;
        p.stake = uint128(msg.value);
        p.createdAt = uint64(block.timestamp);
        emit PetitionCreated(id, msg.sender, title, p.stake, p.createdAt + POLL_TIMEOUT);
    }

    /// @notice Firma una raccolta (una sola volta per indirizzo), solo finché è aperta.
    /// @param id Indice della petizione da firmare.
    function sign(uint256 id) external {
        Petition storage p = _petitions[id];
        if (p.creator == address(0)) revert BadPoll();
        if (block.timestamp >= p.createdAt + POLL_TIMEOUT) revert SigningClosed();
        if (hasSigned[id][msg.sender]) revert AlreadyVoted();
        hasSigned[id][msg.sender] = true;
        p.signatureCount += 1;
        emit Signed(id, msg.sender, p.signatureCount);
    }

    /// @notice Liquida la cauzione dopo la scadenza. Riservato al creatore, una sola volta.
    ///         Quorum raggiunto -> 100% al creatore; sotto soglia -> 50% allo Stato + 50% al
    ///         creatore (il resto della divisione intera va al creatore: nessun wei perso).
    /// @param id Indice della petizione (il chiamante deve esserne il creatore).
    function claim(uint256 id) external {
        Petition storage p = _petitions[id];
        if (msg.sender != p.creator) revert NotCreator();
        if (block.timestamp < p.createdAt + POLL_TIMEOUT) revert StillOpen();
        if (p.claimed) revert AlreadyClaimed();
        p.claimed = true; // checks-effects-interactions

        uint256 stakeAmt = uint256(p.stake);
        bool reached = p.signatureCount >= MIN_SIGNATURES;
        uint256 toState = reached ? 0 : stakeAmt / 2; // penale anti-spam
        uint256 refunded = stakeAmt - toState; // creatore (incassa l'eventuale resto dispari)

        if (toState > 0) {
            (bool okState,) = payable(government).call{value: toState}("");
            require(okState, "state payout failed");
        }
        (bool ok,) = payable(p.creator).call{value: refunded}("");
        require(ok, "refund failed");
        emit StakeResolved(id, p.creator, refunded, toState, reached);
    }

    // ------------------------------------------------------------------------------ GOVERNO
    /// @notice Valutazione istituzionale (segnale on-chain): il governo approva o respinge in
    ///         via DEFINITIVA una raccolta che ha raggiunto MIN_SIGNATURES. Non muove la
    ///         cauzione: il rimborso dipende solo dalle firme e dalla scadenza.
    /// @param id      Indice della petizione.
    /// @param approve true = approvata, false = respinta.
    function decide(uint256 id, bool approve) external onlyGov {
        Petition storage p = _petitions[id];
        if (p.creator == address(0)) revert BadPoll();
        if (p.signatureCount < MIN_SIGNATURES) revert BelowMinVotes();
        if (p.decided) revert AlreadyDecided(); // finalità: niente più cambio di idea
        p.approved = approve;
        p.decided = true;
        emit PetitionDecided(id, msg.sender, approve);
    }

    // -------------------------------------------------------------------------------- VIEWS
    /// @notice Numero totale di petizioni create.
    function petitionsCount() external view returns (uint256) {
        return _petitions.length;
    }

    /// @notice Timestamp di scadenza della raccolta firme (oltre il quale si può fare claim).
    /// @param id Indice della petizione.
    function deadline(uint256 id) external view returns (uint256) {
        return uint256(_petitions[id].createdAt) + POLL_TIMEOUT;
    }

    /// @notice Dati completi: creator, title, description, stake, signatureCount, createdAt,
    ///         approved, decided, claimed.
    /// @param id Indice della petizione.
    function getPetition(uint256 id)
        external
        view
        returns (
            address creator,
            string memory title,
            string memory description,
            uint128 stake,
            uint64 signatureCount,
            uint64 createdAt,
            bool approved,
            bool decided,
            bool claimed
        )
    {
        Petition storage p = _petitions[id];
        return
            (
                p.creator,
                p.title,
                p.description,
                p.stake,
                p.signatureCount,
                p.createdAt,
                p.approved,
                p.decided,
                p.claimed
            );
    }
}
