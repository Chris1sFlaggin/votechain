// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Roles} from "./Roles.sol";

/// @title SPIDWalletRouter — (simulated) SPID authorisation + electoral geofencing.
/// @notice On-chain projection of the off-chain SPID step. A real accredited IdP
///         cannot run on-chain; here a citizen self-enrols from their own wallet k_i
///         (e.g. MetaMask) declaring a jurisdiction — a pure PoC of the flow.
///         The authorisation is created PER REFERENDUM: a (fake) SPID identity is
///         bound to the pair (referendum, wallet). The same wallet must create a
///         FRESH identity for each referendum it wants to vote in, and an identity
///         created for one referendum never authorises another one.
///         NO personal data reaches the chain — not even a pseudonym: only the
///         chosen jurisdiction is stored. Name, surname and codice fiscale never
///         leave the client. Governments are registered per jurisdiction by the
///         ADMIN. Geofencing is enforced on-chain via canVote()/isGovernment().
///
/// @dev SECURITY (PoC): simulatedSpidLogin() trusts the caller — anyone can enrol any
///      jurisdiction. In production an accredited IdP + off-chain oracle
///      would issue the authorisation (binding the jurisdiction to the verified
///      identity) before it is written here.
contract SPIDWalletRouter is Roles {
    struct Wallet {
        bool authorized;
        string jurisdiction;
    }

    // (referendum, k_i) => authorisation — one (fake) SPID identity per referendum
    mapping(address => mapping(address => Wallet)) private _wallets;
    // a government may oversee one or more jurisdictions
    mapping(address => mapping(bytes32 => bool)) private _govFor; // gov => keccak(jurisdiction)
    mapping(address => bool) private _isAuthority; // gov di almeno una giurisdizione (per PollHub)

    event GovernmentRegistered(address indexed government, string jurisdiction);
    event WalletAuthorized(address indexed referendum, address indexed wallet, string jurisdiction);

    constructor() Roles(msg.sender) {
        _grant(ORACLE, msg.sender); // deployer doubles as the simulated SPID oracle
    }

    // ------------------------------------------------------------- admin (setup)
    /// @notice Register a government for a jurisdiction (may create referenda there).
    ///         Can be called multiple times to grant several jurisdictions.
    function registerGovernment(address government, string calldata jurisdiction) external onlyRole(ADMIN) {
        _govFor[government][keccak256(bytes(jurisdiction))] = true;
        _isAuthority[government] = true;
        emit GovernmentRegistered(government, jurisdiction);
    }

    // ------------------------------------------------- simulated SPID (static-site)
    /// @notice SIMULATED SPID login: the caller's wallet k_i self-enrols a fresh
    ///         identity FOR A SPECIFIC referendum, declaring a jurisdiction. NO
    ///         identity data is stored on-chain — not even a pseudonym: only the
    ///         chosen jurisdiction, bound to (referendum, wallet). The same wallet
    ///         must repeat this for every referendum; an identity does not carry over.
    ///         Callable directly from a static frontend with no backend.
    function simulatedSpidLogin(address referendum, string calldata jurisdiction) external {
        _wallets[referendum][msg.sender] = Wallet(true, jurisdiction);
        emit WalletAuthorized(referendum, msg.sender, jurisdiction);
    }

    // -------------------------------------------------------------- views (reads)
    function isAuthorized(address referendum, address wallet) external view returns (bool) {
        return _wallets[referendum][wallet].authorized;
    }

    function jurisdictionOf(address referendum, address wallet) external view returns (string memory) {
        return _wallets[referendum][wallet].jurisdiction;
    }

    /// @notice Geofencing: may `wallet` vote in `referendum` of `refJurisdiction`?
    ///         True only if it created a (fake) SPID identity for THAT referendum
    ///         in the matching jurisdiction.
    function canVote(address referendum, address wallet, string calldata refJurisdiction) external view returns (bool) {
        Wallet memory w = _wallets[referendum][wallet];
        return w.authorized && _eq(w.jurisdiction, refJurisdiction);
    }

    function isGovernment(address government, string calldata jurisdiction) external view returns (bool) {
        return _govFor[government][keccak256(bytes(jurisdiction))];
    }

    /// @notice È un governo di almeno una giurisdizione? (usato da PollHub per l'endorsement)
    function isAuthority(address who) external view returns (bool) {
        return _isAuthority[who];
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
