// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Errors} from "../utils/Errors.sol";

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
