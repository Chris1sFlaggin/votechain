// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  factory: "0xB64FB9acc87C233EA15010c702BB95BfB9c3a2B2", // indirizzo GovFactory su Sepolia
  pollHub: "0x57Abd92f58153B45e91FD1132A6d6A91cCfB6e06", // indirizzo PollHub su Sepolia
};
