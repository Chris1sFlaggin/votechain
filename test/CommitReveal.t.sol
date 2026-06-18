// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SPIDWalletRouter} from "../src/auth/SPIDWalletRouter.sol";
import {GovFactory} from "../src/core/GovFactory.sol";
import {Referendum} from "../src/core/Referendum.sol";
import {IReferendum} from "../src/interfaces/IReferendum.sol";
import {VoteVerifier} from "../src/crypto/VoteVerifier.sol";
import {Errors} from "../src/utils/Errors.sol";

/// Hash collisions, nonce uniqueness and multi-reveal semantics.
contract CommitRevealTest is Test {
    SPIDWalletRouter router;
    GovFactory factory;
    Referendum ref;

    address govIT = makeAddr("govIT");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 constant SI = bytes32("si");
    bytes32 constant NO = bytes32("no");

    function setUp() public {
        router = new SPIDWalletRouter();
        factory = new GovFactory(router);
        router.registerGovernment(govIT, "Italia");

        bytes32[] memory opts = new bytes32[](2);
        opts[0] = SI;
        opts[1] = NO;
        vm.prank(govIT);
        ref = Referendum(factory.createReferendum("R", "Italia", opts));

        vm.prank(alice);
        router.simulatedSpidLogin(address(ref), "Italia");
        vm.prank(bob);
        router.simulatedSpidLogin(address(ref), "Italia");
    }

    function _d(bytes32 v, string memory n) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(v, n));
    }

    /// The digest excludes the voter, so identical (vote,nonce) from two voters collide.
    function test_sameVoteNonceCollides() public {
        bytes32 d = _d(SI, "dup");
        vm.prank(alice);
        ref.commit(d);
        vm.prank(bob);
        vm.expectRevert(Errors.NonceGiaUtilizzato.selector);
        ref.commit(d);
    }

    /// Re-voting with the same nonce is rejected (must pick a fresh nonce).
    function test_reusedNonceBySameVoterRejected() public {
        vm.startPrank(alice);
        ref.commit(_d(SI, "n"));
        vm.expectRevert(Errors.NonceGiaUtilizzato.selector);
        ref.commit(_d(SI, "n")); // same digest
        vm.stopPrank();
    }

    /// Different option but reused nonce -> different digest -> allowed.
    function test_freshNonceAllowsRevote() public {
        vm.startPrank(alice);
        ref.commit(_d(SI, "n"));
        ref.commit(_d(NO, "m")); // fresh
        vm.stopPrank();
        assertEq(ref.revisions(alice), 2);
    }

    /// The last reveal wins, even after an earlier mismatching reveal.
    function test_multiRevealLastWins() public {
        vm.prank(alice);
        ref.commit(_d(NO, "secret"));
        vm.prank(govIT);
        ref.setPhase(IReferendum.Phase.Tally);
        vm.prank(alice); // mismatch, recorded in clear
        ref.reveal(SI, "x");
        vm.prank(alice); // match (last)
        ref.reveal(NO, "secret");
        vm.prank(govIT);
        ref.close();
        assertEq(ref.result(NO), 1);
        assertEq(ref.result(SI), 0);
    }

    function test_verifierMatchMath() public pure {
        bytes32 d = keccak256(abi.encodePacked(SI, "abc"));
        assertTrue(VoteVerifier.matches(SI, "abc", d));
        assertFalse(VoteVerifier.matches(SI, "abd", d));
        assertFalse(VoteVerifier.matches(NO, "abc", d));
    }
}
