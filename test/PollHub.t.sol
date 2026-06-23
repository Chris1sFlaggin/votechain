// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    PollHub,
    NotGovernment,
    BadPoll,
    AlreadyVoted,
    PollNotWon,
    NotCreator,
    AlreadyClaimed,
    BelowMinVotes,
    AlreadyDecided,
    NotClosed
} from "../src/social.sol";

/// Petizioni: cauzione + raccolta firme + rimborso se approvato dal governo (deployer).
contract PollHubTest is Test {
    PollHub hub;
    address gov = makeAddr("gov"); // deployer = governo
    address creator = makeAddr("creator");

    event PeriodClosed(uint256 indexed round, uint256 forfeited, uint256 approvedStake);

    function setUp() public {
        vm.prank(gov);
        hub = new PollHub(); // gov = government
        vm.deal(creator, 1 ether);
    }

    // firma `n` volte da `n` indirizzi distinti
    function _signN(uint256 id, uint256 n, uint256 seed) internal {
        for (uint256 i; i < n; i++) {
            address v = makeAddr(string.concat("v", vm.toString(seed + i)));
            vm.prank(v);
            hub.sign(id);
        }
    }

    function test_decideOnlyGovernment() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        vm.prank(makeAddr("rando"));
        vm.expectRevert(NotGovernment.selector);
        hub.decide(id, true);
    }

    function test_decideBelowMinReverts() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        _signN(id, 4, 1); // 4 < 5
        vm.prank(gov);
        vm.expectRevert(BelowMinVotes.selector);
        hub.decide(id, true);
    }

    function test_governmentDecision() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        _signN(id, 5, 1);
        vm.prank(gov);
        hub.decide(id, true);
        (bool decided, bool approved, address by) = hub.decision(id);
        assertTrue(decided);
        assertTrue(approved);
        assertEq(by, gov);
    }

    function test_decideIsFinal() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        _signN(id, 5, 1);
        vm.prank(gov);
        hub.decide(id, true);
        vm.prank(gov);
        vm.expectRevert(AlreadyDecided.selector);
        hub.decide(id, false); // seconda decisione vietata
    }

    function test_createRequiresStake() public {
        vm.prank(creator);
        vm.expectRevert(BadPoll.selector);
        hub.createPetition("Titolo", "Desc"); // nessuna cauzione
    }

    function test_winsOnApproval() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 0.01 ether}("Petizione", "Descrizione");
        _signN(id, 5, 1);
        (,,,,,, bool decided,) = hub.getPetition(id);
        assertFalse(decided);

        vm.prank(gov);
        hub.decide(id, true);
        (,,,,,, bool decided2,) = hub.getPetition(id);
        assertTrue(decided2);

        vm.prank(gov);
        hub.closePeriod(); // il round va chiuso prima di reclamare

        uint256 bal = creator.balance;
        vm.prank(creator);
        hub.claim(id);
        assertEq(creator.balance, bal + 0.01 ether);
    }

    function test_notApprovedNoClaim() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        _signN(id, 5, 1);
        vm.prank(gov);
        hub.decide(id, false);
        (,,,,, bool approved, bool decided,) = hub.getPetition(id);
        assertTrue(decided);
        assertFalse(approved);
        vm.prank(creator);
        vm.expectRevert(PollNotWon.selector);
        hub.claim(id);
    }

    function test_noDoubleSign() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        address v = makeAddr("dv");
        vm.prank(v);
        hub.sign(id);
        vm.prank(v);
        vm.expectRevert(AlreadyVoted.selector);
        hub.sign(id);
    }

    function test_claimOnlyCreatorAndApproved() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");

        vm.prank(creator);
        vm.expectRevert(PollNotWon.selector);
        hub.claim(id); // non ancora decisa

        _signN(id, 5, 1);
        vm.prank(gov);
        hub.decide(id, true);

        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(NotCreator.selector);
        hub.claim(id); // NotCreator scatta prima del gating sul round

        vm.prank(gov);
        hub.closePeriod();

        vm.prank(creator);
        hub.claim(id);
        vm.prank(creator);
        vm.expectRevert(AlreadyClaimed.selector);
        hub.claim(id);
    }

    function test_decideAccumulatesPerRound() public {
        vm.prank(creator);
        uint256 a = hub.createPetition{value: 0.02 ether}("A", "desc");
        _signN(a, 5, 100);
        vm.prank(gov);
        hub.decide(a, true);

        address creator2 = makeAddr("creator2");
        vm.deal(creator2, 1 ether);
        vm.prank(creator2);
        uint256 b = hub.createPetition{value: 0.01 ether}("B", "desc");
        _signN(b, 5, 200);
        vm.prank(gov);
        hub.decide(b, false);

        assertEq(hub.approvedStakeOf(0), 0.02 ether);
        assertEq(hub.forfeitedOf(0), 0.01 ether);
        assertEq(hub.petitionRound(a), 0);
        assertEq(hub.petitionRound(b), 0);
    }

    function test_closePeriodIncrementsRoundOnlyGov() public {
        assertEq(hub.round(), 0);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(NotGovernment.selector);
        hub.closePeriod();
        vm.prank(gov);
        hub.closePeriod();
        assertEq(hub.round(), 1);
    }

    function test_closePeriodEmits() public {
        vm.expectEmit(true, false, false, true, address(hub));
        emit PeriodClosed(0, 0, 0);
        vm.prank(gov);
        hub.closePeriod();
    }

    function test_claimRevertsBeforeClose() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 0.01 ether}("P", "d");
        _signN(id, 5, 1);
        vm.prank(gov);
        hub.decide(id, true);
        vm.prank(creator);
        vm.expectRevert(NotClosed.selector);
        hub.claim(id); // round non ancora chiuso
    }

    function test_proportionalRoi() public {
        address alice = makeAddr("alice");
        vm.deal(alice, 1 ether);
        address bob = makeAddr("bob");
        vm.deal(bob, 1 ether);
        address carol = makeAddr("carol");
        vm.deal(carol, 1 ether);

        vm.prank(alice);
        uint256 ia = hub.createPetition{value: 10}("A", "d");
        vm.prank(bob);
        uint256 ib = hub.createPetition{value: 30}("B", "d");
        vm.prank(carol);
        uint256 ic = hub.createPetition{value: 40}("C", "d");
        _signN(ia, 5, 10);
        _signN(ib, 5, 20);
        _signN(ic, 5, 30);

        vm.startPrank(gov);
        hub.decide(ia, true);
        hub.decide(ib, true);
        hub.decide(ic, false);
        hub.closePeriod();
        vm.stopPrank();

        uint256 ba = alice.balance;
        uint256 bb = bob.balance;
        vm.prank(alice);
        hub.claim(ia);
        vm.prank(bob);
        hub.claim(ib);
        assertEq(alice.balance - ba, 20); // 10 stake + 10 roi
        assertEq(bob.balance - bb, 60); // 30 stake + 30 roi
    }
}
