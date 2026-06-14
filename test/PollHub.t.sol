// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PollHub} from "../src/social/PollHub.sol";
import {Errors} from "../src/utils/Errors.sol";

/// Sondaggi social: cauzione, soglia di voti, vittoria, rimborso della cauzione.
contract PollHubTest is Test {
    PollHub hub;
    address creator = makeAddr("creator");
    address a1 = makeAddr("a1");
    address a2 = makeAddr("a2");
    address a3 = makeAddr("a3");
    bytes32 constant SI = bytes32("si");
    bytes32 constant NO = bytes32("no");

    function setUp() public {
        hub = new PollHub();
        vm.deal(creator, 1 ether);
    }

    function _opts() internal pure returns (bytes32[] memory o) {
        o = new bytes32[](2);
        o[0] = SI;
        o[1] = NO;
    }

    function test_createRequiresStake() public {
        vm.prank(creator);
        vm.expectRevert(Errors.BadPoll.selector);
        hub.createPoll("Q", _opts(), 3); // nessuna cauzione (msg.value 0)
    }

    function test_create_vote_win_claim() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 0.01 ether}("Pizza o pasta?", _opts(), 3);

        vm.prank(a1);
        hub.vote(id, SI);
        vm.prank(a2);
        hub.vote(id, NO);
        (,,,,, uint64 tv2, bool won2,) = hub.getPoll(id);
        assertEq(tv2, 2);
        assertFalse(won2); // soglia 3 non ancora raggiunta

        vm.prank(a3);
        hub.vote(id, SI); // 3° voto -> vince
        (,,,, uint128 stake, uint64 tv3, bool won3,) = hub.getPoll(id);
        assertEq(tv3, 3);
        assertTrue(won3);

        uint256 bal = creator.balance;
        vm.prank(creator);
        hub.claim(id); // cauzione restituita
        assertEq(creator.balance, bal + stake);
    }

    function test_noDoubleVote() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 1 wei}("Q", _opts(), 5);
        vm.prank(a1);
        hub.vote(id, SI);
        vm.prank(a1);
        vm.expectRevert(Errors.AlreadyVoted.selector);
        hub.vote(id, NO);
    }

    function test_claimOnlyCreatorAndWon() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 1 wei}("Q", _opts(), 1);

        vm.prank(creator);
        vm.expectRevert(Errors.PollNotWon.selector);
        hub.claim(id); // non ancora vinto

        vm.prank(a1);
        hub.vote(id, SI); // vince (soglia 1)

        vm.prank(a2);
        vm.expectRevert(Errors.NotCreator.selector);
        hub.claim(id); // non creatore

        vm.prank(creator);
        hub.claim(id);
        vm.prank(creator);
        vm.expectRevert(Errors.AlreadyClaimed.selector);
        hub.claim(id); // doppio claim
    }

    function test_unknownOption() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 1 wei}("Q", _opts(), 2);
        vm.prank(a1);
        vm.expectRevert(Errors.UnknownOption.selector);
        hub.vote(id, bytes32("xx"));
    }
}
