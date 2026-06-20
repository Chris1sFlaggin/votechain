// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PollHub} from "../src/social/PollHub.sol";
import {SPIDWalletRouter} from "../src/auth/SPIDWalletRouter.sol";
import {Errors} from "../src/utils/Errors.sol";

/// Sondaggi social: cauzione + raccolta firme + rimborso se approvato dal governo.
contract PollHubTest is Test {
    PollHub hub;
    SPIDWalletRouter router;
    address creator = makeAddr("creator");
    address gov = makeAddr("gov");

    function setUp() public {
        router = new SPIDWalletRouter(); // this test = ADMIN
        router.registerGovernment(gov, "Italia");
        hub = new PollHub(router);
        vm.deal(creator, 1 ether);
    }

    function test_decideOnlyGovernment() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        vm.prank(makeAddr("rando"));
        vm.expectRevert(Errors.NotGovernment.selector);
        hub.decide(id, true);
    }

    function test_decideBelowMinReverts() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        _signN(id, 4, 1); // 4 < MIN_SIGNATURES(5)
        vm.prank(gov);
        vm.expectRevert(Errors.BelowMinVotes.selector);
        hub.decide(id, true);
    }

    function test_governmentDecision() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        _signN(id, 5, 1); // supera il minimo
        vm.prank(gov);
        hub.decide(id, true);
        (bool decided, bool approved, address by) = hub.decision(id);
        assertTrue(decided);
        assertTrue(approved);
        assertEq(by, gov);
        // il governo *può* cambiare idea finché non è reclamato
        vm.prank(gov);
        hub.decide(id, false);
        (, bool approved2,) = hub.decision(id);
        assertFalse(approved2);
    }

    // firma `n` volte da `n` indirizzi distinti (seed per evitare collisioni)
    function _signN(uint256 id, uint256 n, uint256 seed) internal {
        for (uint256 i; i < n; i++) {
            address v = makeAddr(string.concat("v", vm.toString(seed + i)));
            vm.prank(v);
            hub.sign(id);
        }
    }

    function test_createRequiresStake() public {
        vm.prank(creator);
        vm.expectRevert(Errors.BadPoll.selector);
        hub.createPetition("Titolo", "Desc"); // nessuna cauzione
    }

    function test_winsOnApproval() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 0.01 ether}("Petizione", "Descrizione petizione");

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
        assertEq(creator.balance, bal + 0.01 ether); // cauzione restituita
    }

    function test_notApprovedNoClaim() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        _signN(id, 5, 1);

        vm.prank(gov);
        hub.decide(id, false); // RESPINTA
        (,,,,, bool approved, bool decided,) = hub.getPetition(id);
        assertTrue(decided);
        assertFalse(approved);

        vm.prank(creator);
        vm.expectRevert(Errors.PollNotWon.selector); // non approvata
        hub.claim(id);
    }

    function test_noDoubleSign() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");
        address v = makeAddr("dv");
        vm.prank(v);
        hub.sign(id);
        vm.prank(v);
        vm.expectRevert(Errors.AlreadyVoted.selector);
        hub.sign(id);
    }

    function test_claimOnlyCreatorAndApproved() public {
        vm.prank(creator);
        uint256 id = hub.createPetition{value: 1 wei}("Titolo", "Desc");

        vm.prank(creator);
        vm.expectRevert(Errors.PollNotWon.selector);
        hub.claim(id); // non ancora decisa

        _signN(id, 5, 1); // 5-0 -> approvabile
        vm.prank(gov);
        hub.decide(id, true);

        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(Errors.NotCreator.selector);
        hub.claim(id);

        vm.prank(creator);
        hub.claim(id);
        vm.prank(creator);
        vm.expectRevert(Errors.AlreadyClaimed.selector);
        hub.claim(id);
    }
}
