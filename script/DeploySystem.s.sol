// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SPIDWalletRouter} from "../src/auth/SPIDWalletRouter.sol";
import {GovFactory} from "../src/core/GovFactory.sol";
import {PollHub} from "../src/social/PollHub.sol";

/// @title DeploySystem — wires the system and issues one referendum per jurisdiction.
/// @notice Run against a local anvil node:
///   anvil &
///   forge script script/DeploySystem.s.sol --rpc-url http://127.0.0.1:8545 \
///        --private-key <anvil_key> --broadcast
/// Voters self-enrol a fake SPID identity from the dApp; nothing is pre-seeded.
contract DeploySystem is Script {
    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender; // ADMIN + ORACLE

        SPIDWalletRouter router = new SPIDWalletRouter();
        GovFactory factory = new GovFactory(router);
        PollHub pollHub = new PollHub(router); // social side: open polls + government endorsement

        // the deployer doubles as both governments for the local demo
        router.registerGovernment(deployer, "Italia");
        router.registerGovernment(deployer, "San Marino");

        // a second, fixed government wallet (mirrors SystemBootstrap.EXTRA_GOV)
        address extraGov = 0x22a2bc6E24FBa136023A126560E2D2490A834B54;
        router.registerGovernment(extraGov, "Italia");
        router.registerGovernment(extraGov, "San Marino");

        // issue one referendum per jurisdiction (demo content)
        string[] memory itOpts = new string[](3);
        itOpts[0] = "si";
        itOpts[1] = "no";
        itOpts[2] = "bianca";
        address refIT = factory.createReferendum("Referendum Costituzionale 2026", "Italia", itOpts);

        string[] memory smOpts = new string[](2);
        smOpts[0] = "si";
        smOpts[1] = "no";
        address refSM = factory.createReferendum("Referendum di San Marino 2026", "San Marino", smOpts);

        vm.stopBroadcast();

        console.log("SPIDWalletRouter:", address(router));
        console.log("GovFactory      :", address(factory));
        console.log("PollHub         :", address(pollHub));
        console.log("Referendum IT   :", refIT);
        console.log("Referendum SM   :", refSM);
    }
}
