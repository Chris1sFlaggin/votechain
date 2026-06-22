// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GovFactory} from "../src/referendum.sol";
import {PollHub} from "../src/social.sol";

/// @title DeploySystem — deploya i due contratti (deployer = governo) e crea 2 referendum demo.
///   anvil &
///   forge script script/DeploySystem.s.sol --rpc-url http://127.0.0.1:8545 \
///        --private-key <anvil_key> --broadcast
contract DeploySystem is Script {
    function run() external {
        vm.startBroadcast();

        GovFactory factory = new GovFactory(); // deployer = governo
        PollHub pollHub = new PollHub(); // deployer = governo

        string[] memory opts3 = new string[](3);
        opts3[0] = "si";
        opts3[1] = "no";
        opts3[2] = "bianca";
        address ref1 = factory.createReferendum("Referendum Costituzionale 2026", opts3);

        string[] memory opts2 = new string[](2);
        opts2[0] = "si";
        opts2[1] = "no";
        address ref2 = factory.createReferendum("Referendum 2026", opts2);

        vm.stopBroadcast();

        console.log("GovFactory  :", address(factory));
        console.log("PollHub     :", address(pollHub));
        console.log("Referendum 1:", ref1);
        console.log("Referendum 2:", ref2);
    }
}
