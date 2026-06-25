// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  name: "Sepolia",
  factory: "0x7EF2e0048f5bAeDe046f6BF797943daF4ED8CB47", // indirizzo GovFactory su Sepolia
  pollHub: "0xD7ACd2a9FD159E69Bb102A1ca21C9a3e3A5F771B", // indirizzo PollHub su Sepolia
};
