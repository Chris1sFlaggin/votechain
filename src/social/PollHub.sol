// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Errors} from "../utils/Errors.sol";

/// @title PollHub — sondaggi "social" aperti a tutti (lato non istituzionale).
/// @notice Chiunque crea un sondaggio depositando una **cauzione** (stake) e fissando
///         una **soglia di voti**. Chiunque vota una volta sola. Quando il sondaggio
///         raggiunge la soglia "vince" e il creatore può **riprendersi la cauzione**
///         (il gas speso gli torna indietro). Se non raggiunge mai la soglia, la
///         cauzione resta bloccata nel contratto (disincentivo agli spam-poll).
///         Nessuna identità/SPID/giurisdizione: è la parte aperta e social.
contract PollHub {
    struct Poll {
        address creator;
        string question;
        bytes32[] options;
        uint64 threshold; // voti necessari perché il sondaggio "vinca"
        uint128 stake; // cauzione del creatore (wei)
        uint64 totalVotes;
        bool won;
        bool claimed;
    }

    Poll[] private _polls; // pollId = indice
    mapping(uint256 => mapping(bytes32 => uint256)) public votesOf; // pollId => opzione => conteggio
    mapping(uint256 => mapping(address => bool)) public hasVoted; // pollId => votante => bool

    event PollCreated(uint256 indexed id, address indexed creator, string question, uint64 threshold, uint128 stake);
    event Voted(uint256 indexed id, address indexed voter, bytes32 option, uint64 totalVotes);
    event PollWon(uint256 indexed id);
    event StakeClaimed(uint256 indexed id, address indexed creator, uint128 amount);

    /// @notice Crea un sondaggio depositando la cauzione (msg.value).
    function createPoll(string calldata question, bytes32[] calldata options, uint64 threshold)
        external
        payable
        returns (uint256 id)
    {
        if (options.length < 2 || threshold == 0 || msg.value == 0 || bytes(question).length == 0) {
            revert Errors.BadPoll();
        }
        id = _polls.length;
        Poll storage p = _polls.push();
        p.creator = msg.sender;
        p.question = question;
        p.options = options;
        p.threshold = threshold;
        p.stake = uint128(msg.value);
        emit PollCreated(id, msg.sender, question, threshold, p.stake);
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

        if (!p.won && p.totalVotes >= p.threshold) {
            p.won = true;
            emit PollWon(id);
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
            uint64 threshold,
            uint128 stake,
            uint64 totalVotes,
            bool won,
            bool claimed
        )
    {
        Poll storage p = _polls[id];
        return (p.creator, p.question, p.options, p.threshold, p.stake, p.totalVotes, p.won, p.claimed);
    }

    function optionVotes(uint256 id, bytes32 option) external view returns (uint256) {
        return votesOf[id][option];
    }

    function _isOption(Poll storage p, bytes32 o) internal view returns (bool) {
        for (uint256 i; i < p.options.length; ++i) {
            if (p.options[i] == o) return true;
        }
        return false;
    }
}
