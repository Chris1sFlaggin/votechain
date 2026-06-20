// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Errors} from "../utils/Errors.sol";
import {SPIDWalletRouter} from "../auth/SPIDWalletRouter.sol";

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
