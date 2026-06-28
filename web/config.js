// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  name: "Sepolia",
  factory: "0xcC09381d4684BD07cFDf3ff022b6a5fB410d3235", // indirizzo GovFactory su Sepolia
  pollHub: "0x57A733D933A29D91b42e3e467fb12428d26cd128", // indirizzo PollHub su Sepolia
};
