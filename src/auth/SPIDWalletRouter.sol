// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Roles} from "./Roles.sol";

/// @title SPIDWalletRouter — (simulated) SPID authorisation + electoral geofencing.
/// @notice On-chain projection of the off-chain SPID step. A real accredited IdP
///         cannot run on-chain; here a citizen self-enrols from their own wallet k_i
///         (e.g. MetaMask) declaring a jurisdiction — a pure PoC of the flow.
///         NO personal data is involved: only keccak256(codice fiscale) — a
///         pseudonym — is passed; name/surname never reach the chain and are never
///         stored. Governments are registered per jurisdiction by the ADMIN.
///         Geofencing is enforced on-chain via canVote()/isGovernment().
///
/// @dev SECURITY (PoC): simulatedSpidLogin() trusts the caller — anyone can enrol any
///      pseudonym/jurisdiction. In production an accredited IdP + off-chain oracle
///      would issue the authorisation (binding the jurisdiction to the verified
///      identity) before it is written here.
contract SPIDWalletRouter is Roles {
    struct Wallet {
        bool authorized;
        string jurisdiction;
        bytes32 cfHash; // pseudonym = keccak256(codice fiscale); no name on-chain
    }

    mapping(address => Wallet) private _wallets; // k_i => authorisation
    // a government may oversee one or more jurisdictions
    mapping(address => mapping(bytes32 => bool)) private _govFor; // gov => keccak(jurisdiction)

    event GovernmentRegistered(address indexed government, string jurisdiction);
    event WalletAuthorized(address indexed wallet, bytes32 indexed cfHash, string jurisdiction);

    constructor() Roles(msg.sender) {
        _grant(ORACLE, msg.sender); // deployer doubles as the simulated SPID oracle
    }

    // ------------------------------------------------------------- admin (setup)
    /// @notice Register a government for a jurisdiction (may create referenda there).
    ///         Can be called multiple times to grant several jurisdictions.
    function registerGovernment(address government, string calldata jurisdiction) external onlyRole(ADMIN) {
        _govFor[government][keccak256(bytes(jurisdiction))] = true;
        emit GovernmentRegistered(government, jurisdiction);
    }

    // ------------------------------------------------- simulated SPID (static-site)
    /// @notice SIMULATED SPID login: the caller's wallet k_i self-enrols for a
    ///         jurisdiction under the pseudonym `cfHash` (= keccak256 of a codice
    ///         fiscale). No name/surname is stored — only the pseudonym. Callable
    ///         directly from a static frontend with no backend.
    function simulatedSpidLogin(bytes32 cfHash, string calldata jurisdiction) external {
        _wallets[msg.sender] = Wallet(true, jurisdiction, cfHash);
        emit WalletAuthorized(msg.sender, cfHash, jurisdiction);
    }

    // -------------------------------------------------------------- views (reads)
    function isAuthorized(address wallet) external view returns (bool) {
        return _wallets[wallet].authorized;
    }

    function jurisdictionOf(address wallet) external view returns (string memory) {
        return _wallets[wallet].jurisdiction;
    }

    /// @notice Geofencing: may `wallet` vote in a referendum of `refJurisdiction`?
    function canVote(address wallet, string calldata refJurisdiction) external view returns (bool) {
        Wallet memory w = _wallets[wallet];
        return w.authorized && _eq(w.jurisdiction, refJurisdiction);
    }

    function isGovernment(address government, string calldata jurisdiction) external view returns (bool) {
        return _govFor[government][keccak256(bytes(jurisdiction))];
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
