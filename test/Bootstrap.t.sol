// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SystemBootstrap} from "../src/SystemBootstrap.sol";
import {SPIDWalletRouter} from "../src/auth/SPIDWalletRouter.sol";
import {GovFactory} from "../src/core/GovFactory.sol";
import {Referendum} from "../src/core/Referendum.sol";
import {IReferendum} from "../src/interfaces/IReferendum.sol";

/// One-click bootstrap: roles + governments, then self-enrol and a real vote.
contract BootstrapTest is Test {
    address gov = makeAddr("gov"); // the human deployer (tx.origin)
    address voter = makeAddr("voter");

    SystemBootstrap boot;
    SPIDWalletRouter router;
    GovFactory factory;

    function setUp() public {
        vm.prank(gov, gov); // msg.sender AND tx.origin = gov
        boot = new SystemBootstrap();
        router = boot.router();
        factory = boot.factory();
    }

    function test_deployerIsAdminOracleAndGovernment() public view {
        assertTrue(router.hasRole(router.ADMIN(), gov));
        assertTrue(router.hasRole(router.ORACLE(), gov));
        assertTrue(router.isGovernment(gov, "Italia"));
        assertTrue(router.isGovernment(gov, "San Marino"));
    }

    function test_selfEnrollAndGeofencing() public {
        // anyone can self-enrol a fake SPID identity for a chosen jurisdiction
        vm.prank(voter);
        router.simulatedSpidLogin(keccak256("any-fake-cf"), "Italia");
        assertTrue(router.canVote(voter, "Italia"));
        assertFalse(router.canVote(voter, "San Marino"));
    }

    function test_fullFlowFromBootstrappedSystem() public {
        bytes32[] memory opts = new bytes32[](2);
        opts[0] = bytes32("si");
        opts[1] = bytes32("no");
        vm.prank(gov);
        Referendum r = Referendum(factory.createReferendum("Ref", "Italia", opts));

        vm.prank(voter);
        router.simulatedSpidLogin(keccak256("any-fake-cf"), "Italia");

        bytes32 digest = keccak256(abi.encodePacked(bytes32("si"), "n1"));
        vm.prank(voter);
        r.commit(digest);
        vm.prank(gov);
        r.setPhase(IReferendum.Phase.Tally);
        vm.prank(voter);
        r.reveal(bytes32("si"), "n1");
        vm.prank(gov);
        r.close();

        assertEq(r.result(bytes32("si")), 1);
    }
}
