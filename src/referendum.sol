// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// VoteChain — referendum istituzionali (commit–reveal). Governo = chi fa il deploy.
// Nessuna autenticazione SPID, nessuna giurisdizione. Il deployer della
// GovFactory è il governo del proprio sistema: emette i referendum e ne guida
// le fasi (Votazione → Spoglio → Chiuso). I cittadini votano col solo wallet,
// un voto a testa. Il voto resta nascosto dietro keccak256(voto, nonce) fino
// al reveal. Errori e verifier sono inlineati: il file è autosufficiente.

// ----------------------------------------------------------------- errori (gas-efficient)
error NotGovernment();
error GovernmentCannotVote();
error NonceGiaUtilizzato();
error VotingNotOpen();
error RevealClosed();
error NoVote();
error AlreadyRevealed();
error CloseOnlyFromTally();
error AlreadyFinalized();
error EmptyOptions();

/// @title Referendum — un singolo referendum nelle sue tre fasi.
///  PHASE 1 VOTING  — commit(digest, nonceTag): nonce unico per-wallet; re-voto ammesso,
///                    conta solo l'ultimo. Nessun reveal qui (nessun conteggio in corso).
///  PHASE 2 TALLY   — niente nuovi digest; reveal aperto.
///  reveal(nonce)   — solo il nonce: il contratto prova ogni opzione e conferma quella il
///                    cui keccak256(opzione,nonce) == lastDigest. Un reveal corretto blocca
///                    la scheda; un nonce errato non conferma nulla (ritentabile).
///  PHASE 3 CLOSED  — close() conta, per wallet, il voto confermato.
contract Referendum {
    enum Phase {
        Setup,
        Voting,
        Tally,
        Closed
    }

    address public immutable government;
    string public title;
    Phase public phase;
    bool public finalized;

    bytes32[] public options; // id UNICI (due label uguali -> id diversi)
    string[] private _labels; // label umane, parallele a options (possono ripetersi)
    mapping(bytes32 => uint256) public tally; // id opzione => voti confermati (a close)

    struct Ballot {
        bytes32 lastDigest; // conta solo l'ultimo digest
        bool committed;
        bool confirmed; // reveal corretto avvenuto -> scheda bloccata
        bytes32 vote; // opzione dedotta alla conferma
        string nonce; // nonce confermato
    }
    mapping(address => Ballot) public ballots; // wallet => scheda
    mapping(address => uint32) public revisions; // wallet => numero (ri)voti
    // dominio nonce PER WALLET: votante => keccak(nonce) => usato
    mapping(address => mapping(bytes32 => bool)) public usedNonce;
    address[] public voters; // wallet partecipanti, per il conteggio

    uint256 public committedCount;
    uint256 public revealedCount;

    event Committed(address indexed voter, bytes32 digest, uint32 revision);
    event Revealed(address indexed voter, string vote, string nonce, bool matches);
    event PhaseChanged(Phase phase);
    event Finalized(uint256 valid, uint256 nullified);

    modifier onlyGov() {
        if (msg.sender != government) revert NotGovernment();
        _;
    }

    constructor(address gov, string memory _title, string[] memory optionLabels) {
        government = gov;
        title = _title;
        // ogni opzione riceve un id UNICO anche se due label sono identiche:
        // id = keccak256(this, index, label). La label resta per la visualizzazione.
        for (uint256 i; i < optionLabels.length; ++i) {
            _labels.push(optionLabels[i]);
            options.push(keccak256(abi.encodePacked(address(this), i, optionLabels[i])));
        }
        phase = Phase.Voting; // aperto subito alla creazione
        emit PhaseChanged(phase);
    }

    // ------------------------------------------------- verifier inlineato (ex VoteVerifier)
    /// @dev digest = keccak256(voto + nonce): combacia con quello salvato al commit?
    function _matches(bytes32 vote, string memory nonce, bytes32 stored) private pure returns (bool) {
        return keccak256(abi.encodePacked(vote, nonce)) == stored;
    }

    // -------------------------------------------------------------------------- governo
    /// @notice Il governo fa avanzare la fase del referendum (es. Votazione -> Spoglio).
    /// @param p Nuova fase; non può essere Closed (si usa close()).
    function setPhase(Phase p) external onlyGov {
        if (p == Phase.Closed) revert CloseOnlyFromTally();
        if (finalized) revert AlreadyFinalized();
        phase = p;
        emit PhaseChanged(p);
    }

    /// @notice PHASE 3: chiude e calcola il conteggio ufficiale on-chain.
    function close() external onlyGov {
        if (phase != Phase.Tally) revert CloseOnlyFromTally();
        if (finalized) revert AlreadyFinalized();
        uint256 valid;
        for (uint256 i; i < voters.length; ++i) {
            Ballot storage b = ballots[voters[i]];
            if (!b.confirmed) continue; // solo i voti confermati contano
            tally[b.vote] += 1;
            ++valid;
        }
        finalized = true;
        phase = Phase.Closed;
        emit PhaseChanged(Phase.Closed);
        emit Finalized(valid, committedCount - valid); // nulli = committati ma non confermati
    }

    // ---------------------------------------------------------------------------- elettore
    /// @notice PHASE 1: deposita il digest nascondente del voto. Aperto a qualsiasi wallet.
    /// @param d        keccak256(voto, nonce) — nasconde il voto fino al reveal.
    /// @param nonceTag keccak256(nonce) — impegno sul nonce indipendente dal voto; l'unicità
    ///                 è per-wallet su questo (nonce riusato = errore, con qualunque voto).
    function commit(bytes32 d, bytes32 nonceTag) external {
        if (phase != Phase.Voting) revert VotingNotOpen();
        if (msg.sender == government) revert GovernmentCannotVote(); // separazione dei poteri
        if (usedNonce[msg.sender][nonceTag]) revert NonceGiaUtilizzato();
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

    /// @notice PHASE 2 (Tally): reveal col SOLO nonce. Il contratto prova ogni opzione e
    ///         trova quella il cui digest combacia. Reveal corretto -> scheda bloccata;
    ///         nonce errato -> niente conferma, ritentabile.
    function reveal(string calldata nonce) external {
        if (phase != Phase.Tally) revert RevealClosed();
        Ballot storage b = ballots[msg.sender];
        if (!b.committed) revert NoVote();
        if (b.confirmed) revert AlreadyRevealed();
        for (uint256 i; i < options.length; ++i) {
            if (_matches(options[i], nonce, b.lastDigest)) {
                b.confirmed = true;
                b.vote = options[i];
                b.nonce = nonce;
                revealedCount++;
                emit Revealed(msg.sender, _labels[i], nonce, true);
                return;
            }
        }
        emit Revealed(msg.sender, "", nonce, false); // nessuna opzione combacia
    }

    // ------------------------------------------------------------------------------- views
    /// @notice Gli id unici delle opzioni del referendum.
    function getOptions() external view returns (bytes32[] memory) {
        return options;
    }

    /// @notice Le label leggibili delle opzioni (parallele a getOptions).
    function getLabels() external view returns (string[] memory) {
        return _labels;
    }

    /// @notice Gli indirizzi che hanno partecipato (committato un voto).
    function getVoters() external view returns (address[] memory) {
        return voters;
    }

    /// @notice Voti confermati per una data opzione (significativo solo dopo close()).
    /// @param option Id dell'opzione.
    function result(bytes32 option) external view returns (uint256) {
        return tally[option];
    }

    /// @notice Numero di partecipanti al referendum.
    function votersCount() external view returns (uint256) {
        return voters.length;
    }

    /// @notice Verifica se un id corrisponde a un'opzione valida.
    /// @param o Id da verificare.
    function isOption(bytes32 o) external view returns (bool) {
        for (uint256 i; i < options.length; ++i) {
            if (options[i] == o) return true;
        }
        return false;
    }
}

/// @title GovFactory — il governo (chi fa il deploy) emette i referendum.
/// @notice Niente router/giurisdizioni: l'unico governo è il deployer di questa factory.
///         Ogni referendum creato eredita lo stesso governo.
contract GovFactory {
    address public immutable government;
    address[] private _referenda;

    event ReferendumCreated(address indexed referendum, address indexed government, string title);

    modifier onlyGov() {
        if (msg.sender != government) revert NotGovernment();
        _;
    }

    constructor() {
        government = msg.sender;
    }

    /// @notice Il governo emette un nuovo referendum (minimo 2 opzioni).
    /// @param title        Titolo del referendum.
    /// @param optionLabels Label delle opzioni (>= 2).
    /// @return Indirizzo del contratto Referendum creato.
    function createReferendum(string calldata title, string[] calldata optionLabels)
        external
        onlyGov
        returns (address)
    {
        if (optionLabels.length < 2) revert EmptyOptions();
        Referendum r = new Referendum(government, title, optionLabels);
        _referenda.push(address(r));
        emit ReferendumCreated(address(r), government, title);
        return address(r);
    }

    /// @notice Indirizzi di tutti i referendum creati dalla factory.
    function getReferenda() external view returns (address[] memory) {
        return _referenda;
    }

    /// @notice Numero di referendum creati.
    function count() external view returns (uint256) {
        return _referenda.length;
    }
}
