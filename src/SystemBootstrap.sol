// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SPIDWalletRouter} from "./auth/SPIDWalletRouter.sol";
import {GovFactory} from "./core/GovFactory.sol";
import {PollHub} from "./social/PollHub.sol";

/// @title SystemBootstrap — one-click wiring of the whole system (Remix friendly).
/// @notice Deploy THIS single contract and the system is ready:
///   * deploys SPIDWalletRouter + GovFactory;
///   * makes the deployer (your MetaMask/Remix account) ADMIN + ORACLE and a
///     government for both "Italia" and "San Marino".
/// Then create referenda from your own account via the Factory (so you own/govern
/// them). Voters self-enrol a fake SPID identity straight from the dApp — nothing
/// is pre-seeded, no personal data is stored.
contract SystemBootstrap {
    SPIDWalletRouter public router;
    GovFactory public factory;
    PollHub public pollHub;

    /// @notice Extra government wallet pre-registered at deploy, besides the deployer
    ///         (so it can issue/manage referenda from the dApp's government panel).
    address public constant EXTRA_GOV = 0x22a2bc6E24FBa136023A126560E2D2490A834B54;
    address public constant EXTRA_GOV2 = 0xE6bbD7Ee72Fe05B50e15416B0E03A80C43f3F861;

    event SystemReady(address router, address factory, address pollHub, address government);

    constructor() {
        router = new SPIDWalletRouter(); // this contract becomes ADMIN + ORACLE
        factory = new GovFactory(router);
        pollHub = new PollHub(router); // parte social: sondaggi + endorsement del governo

        address human = tx.origin; // the EOA deploying via Remix/MetaMask
        router.grantRole(router.ADMIN(), human);
        router.grantRole(router.ORACLE(), human);
        router.registerGovernment(human, "Italia");
        router.registerGovernment(human, "San Marino");

        // extra fixed government wallets (Italia + San Marino)
        router.registerGovernment(EXTRA_GOV, "Italia");
        router.registerGovernment(EXTRA_GOV, "San Marino");
        router.registerGovernment(EXTRA_GOV2, "Italia");
        router.registerGovernment(EXTRA_GOV2, "San Marino");

        emit SystemReady(address(router), address(factory), address(pollHub), human);
    }

    /// @notice Convenience read for the frontend: core addresses in one call.
    function addresses() external view returns (address routerAddr, address factoryAddr, address pollHubAddr) {
        return (address(router), address(factory), address(pollHub));
    }
}
