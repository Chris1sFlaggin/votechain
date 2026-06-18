// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Referendum} from "./Referendum.sol";
import {SPIDWalletRouter} from "../auth/SPIDWalletRouter.sol";
import {Errors} from "../utils/Errors.sol";

/// @title GovFactory — lets a registered government deploy new Referendum contracts.
/// @notice The government calls createReferendum() and a dedicated Referendum `i`
///         contract is deployed via `new` (on-chain factory). A government may only
///         create referenda in its OWN jurisdiction (creation-side geofencing,
///         enforced through the SPIDWalletRouter).
contract GovFactory {
    SPIDWalletRouter public immutable router;
    address[] private _referenda;

    event ReferendumCreated(address indexed referendum, address indexed government, string jurisdiction, string title);

    constructor(SPIDWalletRouter _router) {
        router = _router;
    }

    function createReferendum(string calldata title, string calldata jurisdiction, string[] calldata optionLabels)
        external
        returns (address)
    {
        if (!router.isGovernment(msg.sender, jurisdiction)) revert Errors.NotGovernment();
        if (optionLabels.length < 2) revert Errors.EmptyOptions();

        Referendum r = new Referendum(msg.sender, router, title, jurisdiction, optionLabels);
        _referenda.push(address(r));
        emit ReferendumCreated(address(r), msg.sender, jurisdiction, title);
        return address(r);
    }

    function getReferenda() external view returns (address[] memory) {
        return _referenda;
    }

    function count() external view returns (uint256) {
        return _referenda.length;
    }
}
