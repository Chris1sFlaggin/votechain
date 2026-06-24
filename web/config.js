// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  factory: "0x24f1C31d119E957872052A07f738678D9f1C4Cf6", // indirizzo GovFactory su Sepolia
  pollHub: "0x2F51005f781a71d270B755Db3e47838aE85aA739", // indirizzo PollHub su Sepolia
};