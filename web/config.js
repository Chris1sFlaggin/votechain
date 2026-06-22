// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  factory: "", // indirizzo GovFactory su Sepolia
  pollHub: "", // indirizzo PollHub su Sepolia
};
