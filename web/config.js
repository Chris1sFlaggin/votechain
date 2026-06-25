// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  name: "Sepolia",
  factory: "0x65669485cED109768dB843E955f6b455c04D20e4", // indirizzo GovFactory su Sepolia
  pollHub: "0xFb0a81F49527AEAc375F9b253ae20aB8E5a35AdF", // indirizzo PollHub su Sepolia
};
