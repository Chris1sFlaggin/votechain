// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  factory: "0x24f1C31d119E957872052A07f738678D9f1C4Cf6", // indirizzo GovFactory su Sepolia
  pollHub: "0xbb1c74c9ABeBd19a389D2AFcda4AF1F2f780a77d", // indirizzo PollHub su Sepolia
};