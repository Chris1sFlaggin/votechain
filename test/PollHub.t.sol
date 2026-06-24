// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    PollHub,
    NotGovernment,
    BadPoll,
    AlreadyVoted,
    NotCreator,
    AlreadyClaimed,
    BelowMinVotes,
    AlreadyDecided,
    SigningClosed,
    StillOpen
} from "../src/social.sol";

/// Petizioni: cauzione + raccolta firme entro un timeout fisso.
/// Allo scadere: firme >= MIN_SIGNATURES -> rimborso integrale al creatore;
/// firme < MIN_SIGNATURES -> penale 50% allo Stato (governo) + 50% al creatore.
/// La `decide` del governo e' un segnale istituzionale, senza effetti sulla cauzione.
contract PollHubTest is Test {
    PollHub hub;
    address gov = makeAddr("gov"); // deployer = governo = "Stato"
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

    function _create(uint256 stake) internal returns (uint256 id) {
        vm.prank(creator);
        id = hub.createPetition{value: stake}("Titolo", "Desc");
    }

    // ------------------------------------------------------------------ creazione / firma
    function test_createRequiresStake() public {
        vm.prank(creator);
        vm.expectRevert(BadPoll.selector);
        hub.createPetition("Titolo", "Desc"); // nessuna cauzione
    }

    function test_createBelowMinStakeReverts() public {
        uint256 belowMin = hub.MIN_STAKE() - 1; // > 0 ma sotto soglia
        vm.prank(creator);
        vm.expectRevert(BadPoll.selector);
        hub.createPetition{value: belowMin}("Titolo", "Desc");
    }

    function test_signIncrementsWithinWindow() public {
        uint256 id = _create(hub.MIN_STAKE());
        _signN(id, 3, 1);
        (,,,, uint64 sigs,,,,) = hub.getPetition(id);
        assertEq(sigs, 3);
    }

    function test_signAfterTimeoutReverts() public {
        uint256 id = _create(hub.MIN_STAKE());
        skip(hub.POLL_TIMEOUT()); // scaduto
        vm.prank(makeAddr("late"));
        vm.expectRevert(SigningClosed.selector);
        hub.sign(id);
    }

    function test_noDoubleSign() public {
        uint256 id = _create(hub.MIN_STAKE());
        address v = makeAddr("dv");
        vm.prank(v);
        hub.sign(id);
        vm.prank(v);
        vm.expectRevert(AlreadyVoted.selector);
        hub.sign(id);
    }

    // ----------------------------------------------------- decide = segnale istituzionale
    function test_decideOnlyGovernment() public {
        uint256 id = _create(hub.MIN_STAKE());
        vm.prank(makeAddr("rando"));
        vm.expectRevert(NotGovernment.selector);
        hub.decide(id, true);
    }

    function test_decideBelowMinReverts() public {
        uint256 id = _create(hub.MIN_STAKE());
        _signN(id, 4, 1); // 4 < 5
        vm.prank(gov);
        vm.expectRevert(BelowMinVotes.selector);
        hub.decide(id, true);
    }

    function test_governmentDecisionIsSignalOnly() public {
        uint256 id = _create(hub.MIN_STAKE());
        _signN(id, 5, 1);
        vm.prank(gov);
        hub.decide(id, true);
        (,,,,,, bool approved, bool decided,) = hub.getPetition(id);
        assertTrue(decided);
        assertTrue(approved);
    }

    function test_decideIsFinal() public {
        uint256 id = _create(hub.MIN_STAKE());
        _signN(id, 5, 1);
        vm.prank(gov);
        hub.decide(id, true);
        vm.prank(gov);
        vm.expectRevert(AlreadyDecided.selector);
        hub.decide(id, false); // seconda decisione vietata
    }

    // ----------------------------------------------------------------- liquidazione cauzione
    function test_refundFullWhenQuorumReached() public {
        uint256 id = _create(0.01 ether);
        _signN(id, 5, 1);
        skip(hub.POLL_TIMEOUT());

        uint256 balC = creator.balance;
        uint256 balG = gov.balance;
        vm.prank(creator);
        hub.claim(id);
        assertEq(creator.balance - balC, 0.01 ether); // 100% al creatore
        assertEq(gov.balance, balG); // niente allo Stato
    }

    function test_penaltyHalfWhenBelowQuorum() public {
        uint256 id = _create(0.01 ether);
        _signN(id, 4, 1); // sotto soglia
        skip(hub.POLL_TIMEOUT());

        uint256 balC = creator.balance;
        uint256 balG = gov.balance;
        vm.prank(creator);
        hub.claim(id);
        assertEq(creator.balance - balC, 0.005 ether); // 50% al creatore
        assertEq(gov.balance - balG, 0.005 ether); // 50% allo Stato
    }

    function test_oddStakeRemainderToCreator() public {
        uint256 stake = hub.MIN_STAKE() + 1; // importo dispari sopra la soglia
        vm.prank(creator);
        uint256 id = hub.createPetition{value: stake}("Titolo", "Desc");
        _signN(id, 4, 1); // sotto soglia -> split
        skip(hub.POLL_TIMEOUT());

        uint256 balC = creator.balance;
        uint256 balG = gov.balance;
        vm.prank(creator);
        hub.claim(id);
        assertEq(gov.balance - balG, stake / 2); // floor allo Stato
        assertEq(creator.balance - balC, stake - stake / 2); // resto dispari al creatore (nessun wei perso)
    }

    function test_moneyIndependentOfDecision() public {
        // petizione respinta politicamente (decide=false) ma con quorum di firme:
        // il rimborso resta integrale, perche' i soldi non dipendono dalla decide.
        uint256 id = _create(0.01 ether);
        _signN(id, 5, 1);
        vm.prank(gov);
        hub.decide(id, false);
        skip(hub.POLL_TIMEOUT());

        uint256 balC = creator.balance;
        uint256 balG = gov.balance;
        vm.prank(creator);
        hub.claim(id);
        assertEq(creator.balance - balC, 0.01 ether);
        assertEq(gov.balance, balG);
    }

    function test_claimBeforeTimeoutReverts() public {
        uint256 id = _create(0.01 ether);
        _signN(id, 5, 1);
        vm.prank(creator);
        vm.expectRevert(StillOpen.selector);
        hub.claim(id); // finestra ancora aperta
    }

    function test_claimOnlyCreator() public {
        uint256 id = _create(0.01 ether);
        skip(hub.POLL_TIMEOUT());
        vm.prank(makeAddr("other"));
        vm.expectRevert(NotCreator.selector);
        hub.claim(id);
    }

    function test_noDoubleClaim() public {
        uint256 id = _create(0.01 ether);
        _signN(id, 5, 1);
        skip(hub.POLL_TIMEOUT());
        vm.prank(creator);
        hub.claim(id);
        vm.prank(creator);
        vm.expectRevert(AlreadyClaimed.selector);
        hub.claim(id);
    }

    function test_reentrancyNoDoublePayout() public {
        ReentrantCreator atk = new ReentrantCreator(hub);
        vm.deal(address(atk), 1 ether);
        uint256 id = atk.createAndGet{value: 0.01 ether}("P", "d");
        _signN(id, 5, 1);
        skip(hub.POLL_TIMEOUT());

        uint256 before = address(atk).balance;
        atk.doClaim(); // il rientro in receive() trova AlreadyClaimed (CEI) e viene ignorato
        assertEq(address(atk).balance - before, 0.01 ether); // pagato UNA sola volta
    }

    /// Invariante di conservazione: rimborso + quota Stato = stake sempre; lo Stato
    /// prende il 50% (floor) solo sotto soglia, zero altrimenti. Nessun wei perso.
    function testFuzz_splitConservesStake(uint96 rawStake, uint8 sigs) public {
        uint256 stake = bound(rawStake, hub.MIN_STAKE(), 1e18);
        uint256 n = bound(sigs, 0, 8);

        address c = makeAddr("fuzzC");
        vm.deal(c, 2e18);
        vm.prank(c);
        uint256 id = hub.createPetition{value: stake}("A", "d");
        _signN(id, n, 5000);
        skip(hub.POLL_TIMEOUT());

        uint256 balC = c.balance;
        uint256 balG = gov.balance;
        vm.prank(c);
        hub.claim(id);
        uint256 toCreator = c.balance - balC;
        uint256 toState = gov.balance - balG;

        assertEq(toCreator + toState, stake); // conservazione: niente wei persi
        if (n >= hub.MIN_SIGNATURES()) {
            assertEq(toState, 0); // quorum raggiunto -> nessuna penale
        } else {
            assertEq(toState, stake / 2); // sotto soglia -> 50% (floor) allo Stato
        }
    }
}

/// Creator malevolo: prova a rientrare in claim() durante il pagamento.
contract ReentrantCreator {
    PollHub hub;
    uint256 public id;
    bool reentered;

    constructor(PollHub _hub) {
        hub = _hub;
    }

    function createAndGet(string calldata t, string calldata d) external payable returns (uint256) {
        id = hub.createPetition{value: msg.value}(t, d);
        return id;
    }

    function doClaim() external {
        hub.claim(id);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try hub.claim(id) {} catch {} // CEI: il rientro deve fallire (AlreadyClaimed)
        }
    }
}
