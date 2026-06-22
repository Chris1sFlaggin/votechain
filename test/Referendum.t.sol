// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    GovFactory,
    Referendum,
    NotGovernment,
    GovernmentCannotVote,
    VotingNotOpen,
    RevealClosed,
    CloseOnlyFromTally
} from "../src/referendum.sol";

/// Fasi 1/2/3, voto aperto per wallet, nullificazione dei voti non confermati.
contract ReferendumTest is Test {
    GovFactory factory;
    Referendum ref;

    address gov = makeAddr("gov"); // deployer della factory = governo
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 SI;
    bytes32 NO;
    bytes32 BIANCA;

    function setUp() public {
        vm.prank(gov);
        factory = new GovFactory(); // gov = government
        vm.prank(gov);
        ref = Referendum(factory.createReferendum("Referendum Test", _labels()));
        bytes32[] memory o = ref.getOptions();
        SI = o[0];
        NO = o[1];
        BIANCA = o[2];
    }

    function _labels() internal pure returns (string[] memory a) {
        a = new string[](3);
        a[0] = "si";
        a[1] = "no";
        a[2] = "bianca";
    }

    function _digest(bytes32 v, string memory n) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(v, n));
    }

    function _nt(string memory n) internal pure returns (bytes32) {
        return keccak256(bytes(n));
    }

    function test_commitOnlyDuringVoting() public {
        vm.prank(gov);
        ref.setPhase(Referendum.Phase.Tally);
        vm.prank(alice);
        vm.expectRevert(VotingNotOpen.selector);
        ref.commit(_digest(SI, "x"), _nt("x"));
    }

    function test_revoteOnlyLastCounts() public {
        vm.startPrank(alice);
        ref.commit(_digest(SI, "n1"), _nt("n1"));
        ref.commit(_digest(NO, "n2"), _nt("n2"));
        vm.stopPrank();
        (bytes32 last,,,,) = ref.ballots(alice);
        assertEq(last, _digest(NO, "n2"));
        assertEq(ref.revisions(alice), 2);
    }

    function test_revealBlockedDuringVoting() public {
        vm.prank(alice);
        ref.commit(_digest(SI, "an"), _nt("an"));
        vm.prank(alice);
        vm.expectRevert(RevealClosed.selector);
        ref.reveal("an");
    }

    function test_tallyCountAfterReveal() public {
        vm.prank(alice);
        ref.commit(_digest(NO, "an"), _nt("an"));
        vm.prank(bob);
        ref.commit(_digest(SI, "bn"), _nt("bn"));

        vm.prank(gov);
        ref.setPhase(Referendum.Phase.Tally);

        vm.prank(alice);
        ref.reveal("wrong"); // mismatch
        vm.prank(alice);
        ref.reveal("an"); // corretto
        vm.prank(bob);
        ref.reveal("bn");

        vm.prank(gov);
        ref.close();

        assertEq(ref.result(NO), 1);
        assertEq(ref.result(SI), 1);
        assertTrue(ref.finalized());
    }

    function test_wrongNonceNotCounted() public {
        vm.prank(alice);
        ref.commit(_digest(SI, "good"), _nt("good"));
        vm.prank(gov);
        ref.setPhase(Referendum.Phase.Tally);
        vm.prank(alice);
        ref.reveal("bad");
        vm.prank(gov);
        ref.close();
        assertEq(ref.result(SI), 0);
    }

    function test_unrevealedIsNull() public {
        vm.prank(alice);
        ref.commit(_digest(SI, "k"), _nt("k"));
        vm.prank(gov);
        ref.setPhase(Referendum.Phase.Tally);
        vm.prank(gov);
        ref.close();
        assertEq(ref.result(SI), 0);
    }

    function test_onlyGovDrivesPhases() public {
        vm.prank(alice);
        vm.expectRevert(NotGovernment.selector);
        ref.setPhase(Referendum.Phase.Tally);
    }

    function test_closeOnlyFromTally() public {
        vm.prank(gov);
        vm.expectRevert(CloseOnlyFromTally.selector);
        ref.close(); // ancora in Voting
    }

    function test_revealBlockedAfterClose() public {
        vm.prank(alice);
        ref.commit(_digest(SI, "z"), _nt("z"));
        vm.prank(gov);
        ref.setPhase(Referendum.Phase.Tally);
        vm.prank(gov);
        ref.close();
        vm.prank(alice);
        vm.expectRevert(RevealClosed.selector);
        ref.reveal("z");
    }

    function test_governmentCannotVote() public {
        vm.prank(gov);
        vm.expectRevert(GovernmentCannotVote.selector);
        ref.commit(_digest(SI, "g"), _nt("g"));
    }

    function test_onlyGovernmentCreates() public {
        vm.prank(alice);
        vm.expectRevert(NotGovernment.selector);
        factory.createReferendum("X", _labels());
    }
}
