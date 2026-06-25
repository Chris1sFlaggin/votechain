// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GovFactory} from "../src/referendum.sol";
import {PollHub} from "../src/social.sol";

/// @title DeploySystem — deploya i due contratti (deployer = governo), crea 2 referendum demo
///        e, SOLO su anvil locale, seeda 2 raccolte firme demo (una sopra il quorum, una sotto).
///   anvil &
///   forge script script/DeploySystem.s.sol --rpc-url http://127.0.0.1:8545 \
///        --private-key <anvil_key_account0> --broadcast
contract DeploySystem is Script {
    // Chiavi deterministiche di anvil (mnemonic "test test ... junk"), account 1..9.
    // Servono a firmare le petizioni demo da indirizzi DISTINTI. Valide solo in locale.
    uint256 constant K1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant K2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant K3 = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 constant K4 = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 constant K5 = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
    uint256 constant K6 = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
    uint256 constant K7 = 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;
    uint256 constant K8 = 0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97;
    uint256 constant K9 = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;

    function run() external {
        vm.startBroadcast(); // deployer = governo (account 0 passato con --private-key)

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

        // ---- raccolte firme demo: SOLO su anvil locale (firme da account anvil distinti) ----
        uint256 pidA = type(uint256).max;
        uint256 pidB = type(uint256).max;
        if (block.chainid == 31337) {
            // Petizione A: RAGGIUNGE il quorum (5 firme >= MIN_SIGNATURES = 5)
            vm.broadcast(K1);
            pidA = pollHub.createPetition{value: 0.01 ether}(
                "Pista ciclabile in centro", "Realizzare una pista ciclabile protetta sull'asse centrale della citta."
            );
            vm.broadcast(K2);
            pollHub.sign(pidA);
            vm.broadcast(K3);
            pollHub.sign(pidA);
            vm.broadcast(K4);
            pollHub.sign(pidA);
            vm.broadcast(K5);
            pollHub.sign(pidA);
            vm.broadcast(K6);
            pollHub.sign(pidA);

            // Petizione B: NON raggiunge il minimo (2 firme < 5).
            // Diventera liquidabile (50% Stato / 50% proponente) una volta superato il timeout.
            vm.broadcast(K7);
            pidB = pollHub.createPetition{value: 0.005 ether}(
                "Parco giochi in periferia", "Nuova area giochi attrezzata nel quartiere periferico nord."
            );
            vm.broadcast(K8);
            pollHub.sign(pidB);
            vm.broadcast(K9);
            pollHub.sign(pidB);
        }

        console.log("GovFactory  :", address(factory));
        console.log("PollHub     :", address(pollHub));
        console.log("Referendum 1:", ref1);
        console.log("Referendum 2:", ref2);
        if (block.chainid == 31337) {
            console.log("Petizione A (quorum raggiunto, 5 firme) id:", pidA);
            console.log("Petizione B (sotto il minimo, 2 firme)  id:", pidB);
            console.log("Per portare B oltre il timeout (7 giorni), dopo il deploy esegui:");
            console.log("  cast rpc evm_increaseTime 604800 && cast rpc evm_mine");
        }
    }
}
