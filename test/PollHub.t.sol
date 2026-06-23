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
    AlreadyDecided
} from "../src/social.sol";

/// Petizioni: cauzione + raccolta firme + rimborso se approvato dal governo (deployer).
contract PollHubTest is Test {
    PollHub hub;
    address gov = makeAddr("gov"); // deployer = governo
    address creator = makeAddr("creator");

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
        hub.claim(id);

        vm.prank(creator);
        hub.claim(id);
        vm.prank(creator);
        vm.expectRevert(AlreadyClaimed.selector);
        hub.claim(id);
    }
}
