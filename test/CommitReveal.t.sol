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

    function _nt(string memory n) internal pure returns (bytes32) {
        return keccak256(bytes(n)); // impegno sul nonce, indipendente dal voto
    }

    /// The digest excludes the voter, so identical (vote,nonce) from two voters collide.
    function test_sameVoteNonceCollides() public {
        bytes32 d = _d(SI, "dup");
        vm.prank(alice);
        ref.commit(d, _nt("dup"));
        vm.prank(bob);
        vm.expectRevert(Errors.NonceGiaUtilizzato.selector);
        ref.commit(d, _nt("dup"));
    }

    /// Re-voting with the same nonce is rejected (must pick a fresh nonce).
    function test_reusedNonceBySameVoterRejected() public {
        vm.startPrank(alice);
        ref.commit(_d(SI, "n"), _nt("n"));
        vm.expectRevert(Errors.NonceGiaUtilizzato.selector);
        ref.commit(_d(SI, "n"), _nt("n")); // same digest
        vm.stopPrank();
    }

    /// Re-voting is allowed only with a FRESH nonce (new nonce tag).
    function test_freshNonceAllowsRevote() public {
        vm.startPrank(alice);
        ref.commit(_d(SI, "n"), _nt("n"));
        ref.commit(_d(NO, "m"), _nt("m")); // fresh nonce
        vm.stopPrank();
        assertEq(ref.revisions(alice), 2);
    }

    /// Uniqueness is on the NONCE, not on (vote,nonce): the same nonce reused with a
    /// DIFFERENT vote must also be rejected (digest diverso ma stesso nonce).
    function test_sameNonceDifferentVoteRejected() public {
        vm.startPrank(alice);
        ref.commit(_d(SI, "shared"), _nt("shared"));
        vm.expectRevert(Errors.NonceGiaUtilizzato.selector);
        ref.commit(_d(NO, "shared"), _nt("shared")); // voto diverso, stesso nonce
        vm.stopPrank();
    }

    /// Reveal takes ONLY the nonce: the contract tries each option with the committed
    /// nonce and finds the one whose keccak256(option,nonce) matches the stored digest.
    function test_revealWithOnlyNonceFindsVote() public {
        vm.prank(alice);
        ref.commit(_d(NO, "secret"), _nt("secret"));
        vm.prank(govIT);
        ref.setPhase(IReferendum.Phase.Tally);
        vm.prank(alice);
        ref.reveal("secret"); // niente voto: lo deduce il contratto
        (, bool committed, bool confirmed, bytes32 vote,) = ref.ballots(alice);
        assertTrue(committed);
        assertTrue(confirmed);
        assertEq(vote, NO);
    }

    /// A WRONG nonce confirms nothing and can be retried; then the correct one confirms.
    function test_canRetryAfterWrongReveal() public {
        vm.prank(alice);
        ref.commit(_d(NO, "secret"), _nt("secret"));
        vm.prank(govIT);
        ref.setPhase(IReferendum.Phase.Tally);
        vm.prank(alice);
        ref.reveal("x"); // nessuna opzione combacia -> non confermato, nessun revert
        (,, bool confirmedAfterWrong,,) = ref.ballots(alice);
        assertFalse(confirmedAfterWrong);
        vm.prank(alice);
        ref.reveal("secret"); // ora combacia
        vm.prank(govIT);
        ref.close();
        assertEq(ref.result(NO), 1);
        assertEq(ref.result(SI), 0);
    }

    /// After a CORRECT reveal the ballot is locked: re-revealing reverts.
    function test_cannotReRevealAfterCorrect() public {
        vm.prank(alice);
        ref.commit(_d(NO, "secret"), _nt("secret"));
        vm.prank(govIT);
        ref.setPhase(IReferendum.Phase.Tally);
        vm.prank(alice);
        ref.reveal("secret");
        vm.prank(alice);
        vm.expectRevert(Errors.AlreadyRevealed.selector);
        ref.reveal("secret");
    }

    function test_verifierMatchMath() public pure {
        bytes32 d = keccak256(abi.encodePacked(SI, "abc"));
        assertTrue(VoteVerifier.matches(SI, "abc", d));
        assertFalse(VoteVerifier.matches(SI, "abd", d));
        assertFalse(VoteVerifier.matches(NO, "abc", d));
    }
}
