// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SPIDWalletRouter} from "../src/auth/SPIDWalletRouter.sol";
import {GovFactory} from "../src/core/GovFactory.sol";
import {Referendum} from "../src/core/Referendum.sol";
import {IReferendum} from "../src/interfaces/IReferendum.sol";
import {Errors} from "../src/utils/Errors.sol";

/// Phases 1/2/3, geofencing, authorisation, nullification of votes.
contract ReferendumTest is Test {
    SPIDWalletRouter router;
    GovFactory factory;
    Referendum ref;

    address govIT = makeAddr("govIT");
    address alice = makeAddr("alice"); // Italia
    address bob = makeAddr("bob"); // Italia
    address sara = makeAddr("sara"); // San Marino

    bytes32 constant SI = bytes32("si");
    bytes32 constant NO = bytes32("no");
    bytes32 constant BIANCA = bytes32("bianca");

    function setUp() public {
        router = new SPIDWalletRouter(); // this test = ADMIN + ORACLE
        factory = new GovFactory(router);
        router.registerGovernment(govIT, "Italia");

        vm.prank(govIT);
        ref = Referendum(factory.createReferendum("Referendum Test", "Italia", _opts()));

        // voters self-enrol a (fake) SPID identity for a jurisdiction (no CF on-chain)
        vm.prank(alice);
        router.simulatedSpidLogin("Italia");
        vm.prank(bob);
        router.simulatedSpidLogin("Italia");
        vm.prank(sara);
        router.simulatedSpidLogin("San Marino");
    }

    function _opts() internal pure returns (bytes32[] memory a) {
        a = new bytes32[](3);
        a[0] = SI;
        a[1] = NO;
        a[2] = BIANCA;
    }

    function _digest(bytes32 v, string memory n) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(v, n));
    }

    function test_geofencing_outOfJurisdictionReverts() public {
        vm.prank(sara);
        vm.expectRevert(Errors.OutOfJurisdiction.selector);
        ref.commit(_digest(SI, "x"));
    }

    function test_unauthorizedWalletReverts() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.WalletNotAuthorized.selector);
        ref.commit(_digest(SI, "x"));
    }

    function test_commitOnlyDuringVoting() public {
        vm.prank(govIT);
        ref.setPhase(IReferendum.Phase.Tally);
        vm.prank(alice);
        vm.expectRevert(Errors.VotingNotOpen.selector);
        ref.commit(_digest(SI, "x"));
    }

    function test_revoteOnlyLastCounts() public {
        vm.startPrank(alice);
        ref.commit(_digest(SI, "n1"));
        ref.commit(_digest(NO, "n2"));
        vm.stopPrank();
        (bytes32 last,,,,) = ref.ballots(alice);
        assertEq(last, _digest(NO, "n2"));
        assertEq(ref.revisions(alice), 2);
    }

    /// Reveal is NOT allowed while voting is open: no running tally can be built
    /// before the spoglio (presidential-style secrecy).
    function test_revealBlockedDuringVoting() public {
        vm.prank(alice);
        ref.commit(_digest(SI, "an"));
        vm.prank(alice);
        vm.expectRevert(Errors.RevealClosed.selector);
        ref.reveal(SI, "an");
    }

    /// Reveals happen only in Tally; last reveal per wallet wins; count at close.
    function test_tallyCountAfterReveal() public {
        vm.prank(alice);
        ref.commit(_digest(NO, "an"));
        vm.prank(bob);
        ref.commit(_digest(SI, "bn"));

        vm.prank(govIT);
        ref.setPhase(IReferendum.Phase.Tally);

        vm.prank(alice);
        ref.reveal(NO, "wrong"); // mismatch, still recorded in clear
        vm.prank(alice);
        ref.reveal(NO, "an"); // correct (last reveal wins)
        vm.prank(bob);
        ref.reveal(SI, "bn");

        vm.prank(govIT);
        ref.close();

        assertEq(ref.result(NO), 1);
        assertEq(ref.result(SI), 1);
        assertTrue(ref.finalized());
    }

    function test_wrongNonceNotCounted() public {
        vm.prank(alice);
        ref.commit(_digest(SI, "good"));
        vm.prank(govIT);
        ref.setPhase(IReferendum.Phase.Tally);
        vm.prank(alice);
        ref.reveal(SI, "bad"); // mismatch -> null
        vm.prank(govIT);
        ref.close();
        assertEq(ref.result(SI), 0);
    }

    function test_unrevealedIsNull() public {
        vm.prank(alice);
        ref.commit(_digest(SI, "k")); // committed, never revealed
        vm.prank(govIT);
        ref.setPhase(IReferendum.Phase.Tally);
        vm.prank(govIT);
        ref.close();
        assertEq(ref.result(SI), 0);
    }

    function test_onlyGovDrivesPhases() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NotGovernment.selector);
        ref.setPhase(IReferendum.Phase.Tally);
    }

    function test_closeOnlyFromTally() public {
        vm.prank(govIT);
        vm.expectRevert(Errors.CloseOnlyFromTally.selector);
        ref.close(); // still in Voting
    }

    function test_govCannotCreateOutsideJurisdiction() public {
        vm.prank(govIT);
        vm.expectRevert(Errors.NotGovernment.selector);
        factory.createReferendum("X", "San Marino", _opts());
    }

    function test_revealBlockedAfterClose() public {
        vm.prank(alice);
        ref.commit(_digest(SI, "z"));
        vm.prank(govIT);
        ref.setPhase(IReferendum.Phase.Tally);
        vm.prank(govIT);
        ref.close();
        vm.prank(alice);
        vm.expectRevert(Errors.RevealClosed.selector);
        ref.reveal(SI, "z");
    }

    function test_governmentCannotVote() public {
        // even if the government enrols an SPID identity, it cannot commit a vote
        vm.prank(govIT);
        router.simulatedSpidLogin("Italia");
        vm.prank(govIT);
        vm.expectRevert(Errors.GovernmentCannotVote.selector);
        ref.commit(_digest(SI, "g"));
    }
}
