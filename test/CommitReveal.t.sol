// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GovFactory, Referendum, NonceGiaUtilizzato, AlreadyRevealed} from "../src/referendum.sol";

/// Collisioni di hash, unicità del nonce e semantica multi-reveal.
contract CommitRevealTest is Test {
    GovFactory factory;
    Referendum ref;

    address gov = makeAddr("gov");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 SI;
    bytes32 NO;

    function setUp() public {
        vm.prank(gov);
        factory = new GovFactory();
        string[] memory labels = new string[](2);
        labels[0] = "si";
        labels[1] = "no";
        vm.prank(gov);
        ref = Referendum(factory.createReferendum("R", labels));
        bytes32[] memory o = ref.getOptions();
        SI = o[0];
        NO = o[1];
    }

    function _d(bytes32 v, string memory n) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(v, n));
    }

    function _nt(string memory n) internal pure returns (bytes32) {
        return keccak256(bytes(n));
    }

    /// L'unicità del nonce è PER-WALLET: due votanti diversi possono usare lo stesso nonce.
    function test_sameNonceDifferentVotersAllowed() public {
        bytes32 d = _d(SI, "dup");
        vm.prank(alice);
        ref.commit(d, _nt("dup"));
        vm.prank(bob);
        ref.commit(d, _nt("dup"));
        (, bool aliceC,,,) = ref.ballots(alice);
        (, bool bobC,,,) = ref.ballots(bob);
        assertTrue(aliceC);
        assertTrue(bobC);
    }

    /// Stesso votante, stesso nonce -> rifiutato.
    function test_reusedNonceBySameVoterRejected() public {
        vm.startPrank(alice);
        ref.commit(_d(SI, "n"), _nt("n"));
        vm.expectRevert(NonceGiaUtilizzato.selector);
        ref.commit(_d(SI, "n"), _nt("n"));
        vm.stopPrank();
    }

    /// Re-voto ammesso solo con nonce nuovo.
    function test_freshNonceAllowsRevote() public {
        vm.startPrank(alice);
        ref.commit(_d(SI, "n"), _nt("n"));
        ref.commit(_d(NO, "m"), _nt("m"));
        vm.stopPrank();
        assertEq(ref.revisions(alice), 2);
    }

    /// L'unicità è sul NONCE, non su (voto,nonce): stesso nonce + voto diverso -> rifiutato.
    function test_sameNonceDifferentVoteRejected() public {
        vm.startPrank(alice);
        ref.commit(_d(SI, "shared"), _nt("shared"));
        vm.expectRevert(NonceGiaUtilizzato.selector);
        ref.commit(_d(NO, "shared"), _nt("shared"));
        vm.stopPrank();
    }

    /// Reveal col solo nonce: il contratto deduce il voto.
    function test_revealWithOnlyNonceFindsVote() public {
        vm.prank(alice);
        ref.commit(_d(NO, "secret"), _nt("secret"));
        vm.prank(gov);
        ref.setPhase(Referendum.Phase.Tally);
        vm.prank(alice);
        ref.reveal("secret");
        (, bool committed, bool confirmed, bytes32 vote,) = ref.ballots(alice);
        assertTrue(committed);
        assertTrue(confirmed);
        assertEq(vote, NO);
    }

    /// Nonce errato non conferma nulla ed è ritentabile; poi quello giusto conferma.
    function test_canRetryAfterWrongReveal() public {
        vm.prank(alice);
        ref.commit(_d(NO, "secret"), _nt("secret"));
        vm.prank(gov);
        ref.setPhase(Referendum.Phase.Tally);
        vm.prank(alice);
        ref.reveal("x");
        (,, bool confirmedAfterWrong,,) = ref.ballots(alice);
        assertFalse(confirmedAfterWrong);
        vm.prank(alice);
        ref.reveal("secret");
        vm.prank(gov);
        ref.close();
        assertEq(ref.result(NO), 1);
        assertEq(ref.result(SI), 0);
    }

    /// Dopo un reveal corretto la scheda è bloccata.
    function test_cannotReRevealAfterCorrect() public {
        vm.prank(alice);
        ref.commit(_d(NO, "secret"), _nt("secret"));
        vm.prank(gov);
        ref.setPhase(Referendum.Phase.Tally);
        vm.prank(alice);
        ref.reveal("secret");
        vm.prank(alice);
        vm.expectRevert(AlreadyRevealed.selector);
        ref.reveal("secret");
    }

    /// La matematica del digest: keccak256(voto, nonce) deduce l'opzione giusta.
    function test_digestMathDeducesOption() public {
        vm.prank(alice);
        ref.commit(_d(SI, "abc"), _nt("abc"));
        vm.prank(gov);
        ref.setPhase(Referendum.Phase.Tally);
        vm.prank(alice);
        ref.reveal("abc");
        (,,, bytes32 vote,) = ref.ballots(alice);
        assertEq(vote, SI);
    }
}
