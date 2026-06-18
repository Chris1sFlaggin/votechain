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

    function test_extraGovernmentRegistered() public view {
        address extra = 0x22a2bc6E24FBa136023A126560E2D2490A834B54;
        assertTrue(router.isGovernment(extra, "Italia"));
        assertTrue(router.isGovernment(extra, "San Marino"));
    }

    function test_selfEnrollAndGeofencing() public {
        // a referendum is the scope of an identity (one identity per referendum)
        vm.prank(gov);
        Referendum r = Referendum(factory.createReferendum("R", "Italia", _twoOpts()));

        // anyone can self-enrol a fake SPID identity for that referendum
        vm.prank(voter);
        router.simulatedSpidLogin(address(r), "Italia");
        assertTrue(router.canVote(address(r), voter, "Italia"));
        assertFalse(router.canVote(address(r), voter, "San Marino"));
    }

    function _twoOpts() internal pure returns (string[] memory opts) {
        opts = new string[](2);
        opts[0] = "si";
        opts[1] = "no";
    }

    function test_fullFlowFromBootstrappedSystem() public {
        vm.prank(gov);
        Referendum r = Referendum(factory.createReferendum("Ref", "Italia", _twoOpts()));

        vm.prank(voter);
        router.simulatedSpidLogin(address(r), "Italia");

        bytes32 siId = r.getOptions()[0]; // id unico dell'opzione "si"
        bytes32 digest = keccak256(abi.encodePacked(siId, "n1"));
        bytes32 nonceTag = keccak256(bytes("n1"));
        vm.prank(voter);
        r.commit(digest, nonceTag);
        vm.prank(gov);
        r.setPhase(IReferendum.Phase.Tally);
        vm.prank(voter);
        r.reveal("n1");
        vm.prank(gov);
        r.close();

        assertEq(r.result(siId), 1);
    }
}
