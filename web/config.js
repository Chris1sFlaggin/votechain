// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  factory: "0xF0d0018E87B672c51db503239565834A314daa0d", // indirizzo GovFactory su Sepolia
  pollHub: "0x07A435FB521674CF7dd78794936828612c43c902", // indirizzo PollHub su Sepolia
};