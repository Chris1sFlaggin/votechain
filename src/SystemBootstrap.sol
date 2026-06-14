// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SPIDWalletRouter} from "./auth/SPIDWalletRouter.sol";
import {GovFactory} from "./core/GovFactory.sol";

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

    event SystemReady(address router, address factory, address government);

    constructor() {
        router = new SPIDWalletRouter(); // this contract becomes ADMIN + ORACLE
        factory = new GovFactory(router);

        address human = tx.origin; // the EOA deploying via Remix/MetaMask
        router.grantRole(router.ADMIN(), human);
        router.grantRole(router.ORACLE(), human);
        router.registerGovernment(human, "Italia");
        router.registerGovernment(human, "San Marino");

        emit SystemReady(address(router), address(factory), human);
    }

    /// @notice Convenience read for the frontend: both core addresses in one call.
    function addresses() external view returns (address routerAddr, address factoryAddr) {
        return (address(router), address(factory));
    }
}
