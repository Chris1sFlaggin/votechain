// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  factory: "0xF0FC57204F5fEB1c6942A13665259Ed648A52BFd", // indirizzo GovFactory su Sepolia
  pollHub: "0x2eFCf24B4F90b6aCf401d572a9A601f46412Df36", // indirizzo PollHub su Sepolia
};
