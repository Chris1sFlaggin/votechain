// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  name: "Sepolia",
  factory: "0x5D950BCcF6c362dAF34C0c5198cAa218A049a75A", // indirizzo GovFactory su Sepolia
  pollHub: "0x09B6909BA1e3a9289501cD17eaDb6c448682De38", // indirizzo PollHub su Sepolia
};
