// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PollHub} from "../src/social/PollHub.sol";
import {SPIDWalletRouter} from "../src/auth/SPIDWalletRouter.sol";
import {Errors} from "../src/utils/Errors.sol";

/// Sondaggi social: cauzione + vittoria per significatività statistica + rimborso + endorsement governo.
contract PollHubTest is Test {
    PollHub hub;
    SPIDWalletRouter router;
    address creator = makeAddr("creator");
    address gov = makeAddr("gov");
    bytes32 constant SI = bytes32("si");
    bytes32 constant NO = bytes32("no");

    function setUp() public {
        router = new SPIDWalletRouter(); // this test = ADMIN
        router.registerGovernment(gov, "Italia");
        hub = new PollHub(router);
        vm.deal(creator, 1 ether);
    }

    function test_endorseOnlyGovernment() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 1 wei}("Q", _opts());
        vm.prank(makeAddr("rando"));
        vm.expectRevert(Errors.NotGovernment.selector);
        hub.endorse(id, true);
    }

    function test_endorseBelowMinReverts() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 1 wei}("Q", _opts());
        _voteN(id, SI, 4, 1); // 4 < MIN_VOTES(5)
        vm.prank(gov);
        vm.expectRevert(Errors.BelowMinVotes.selector);
        hub.endorse(id, true);
    }

    function test_governmentEndorsement() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 1 wei}("Q", _opts());
        _voteN(id, SI, 5, 1); // supera il minimo
        vm.prank(gov);
        hub.endorse(id, true);
        (bool set, bool approve, address by) = hub.endorsement(id);
        assertTrue(set);
        assertTrue(approve);
        assertEq(by, gov);
        // il governo può cambiare in disapprovazione
        vm.prank(gov);
        hub.endorse(id, false);
        (, bool approve2,) = hub.endorsement(id);
        assertFalse(approve2);
    }

    function _opts() internal pure returns (bytes32[] memory o) {
        o = new bytes32[](2);
        o[0] = SI;
        o[1] = NO;
    }

    // vota `n` opzioni `opt` da `n` indirizzi distinti (seed per evitare collisioni)
    function _voteN(uint256 id, bytes32 opt, uint256 n, uint256 seed) internal {
        for (uint256 i; i < n; i++) {
            address v = makeAddr(string.concat("v", vm.toString(seed + i)));
            vm.prank(v);
            hub.vote(id, opt);
        }
    }

    function test_createRequiresStake() public {
        vm.prank(creator);
        vm.expectRevert(Errors.BadPoll.selector);
        hub.createPoll("Q", _opts()); // nessuna cauzione
    }

    function test_winsOnStatisticalSignificance() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 0.01 ether}("Pizza o pasta?", _opts());

        _voteN(id, SI, 4, 1); // 4-0 ma total 4 < MIN_VOTES(5) -> non vince
        (,,,,, bool won4,) = hub.getPoll(id);
        assertFalse(won4);

        _voteN(id, SI, 1, 100); // 5° voto: 5-0, lead 5, 25 > 4*5=20 -> vince
        (,,, uint128 stake, uint64 total, bool won5,) = hub.getPoll(id);
        assertEq(total, 5);
        assertTrue(won5);

        uint256 bal = creator.balance;
        vm.prank(creator);
        hub.claim(id);
        assertEq(creator.balance, bal + stake); // cauzione restituita
    }

    function test_notSignificantNoWin() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 1 wei}("Q", _opts());
        _voteN(id, SI, 3, 1);
        _voteN(id, NO, 2, 50); // 3-2, total 5, lead 1, 1 > 20? no -> non vince
        (,,,,, bool won,) = hub.getPoll(id);
        assertFalse(won);
        vm.prank(creator);
        vm.expectRevert(Errors.PollNotWon.selector);
        hub.claim(id);
    }

    function test_noDoubleVote() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 1 wei}("Q", _opts());
        address v = makeAddr("dv");
        vm.prank(v);
        hub.vote(id, SI);
        vm.prank(v);
        vm.expectRevert(Errors.AlreadyVoted.selector);
        hub.vote(id, NO);
    }

    function test_claimOnlyCreatorAndWon() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 1 wei}("Q", _opts());

        vm.prank(creator);
        vm.expectRevert(Errors.PollNotWon.selector);
        hub.claim(id); // non ancora vinto

        _voteN(id, SI, 5, 1); // 5-0 -> vince

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

    function test_unknownOption() public {
        vm.prank(creator);
        uint256 id = hub.createPoll{value: 1 wei}("Q", _opts());
        address v = makeAddr("u");
        vm.prank(v);
        vm.expectRevert(Errors.UnknownOption.selector);
        hub.vote(id, bytes32("xx"));
    }
}
