// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  factory: "0x6d4b04B57fc8Bc2B85dac9F1178D037a3c3C15F6", // indirizzo GovFactory su Sepolia
  pollHub: "0x9a679873f5304A3D6DD0b8BC36A6F20547b97427", // indirizzo PollHub su Sepolia
};