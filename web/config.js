// Indirizzi dei contratti deployati (Sepolia testnet). Pubblici: si possono committare.
// GovFactory (referendum.sol) e PollHub (social.sol) deployati separatamente; il deployer
// di ciascuno è il governo del proprio sistema.
const CONFIG = {
  chainId: 11155111, // Sepolia: il sito chiede a MetaMask di passare a questa rete
  factory: "0x6311F9D445fd8C6F1EfE71063ED6853aA30a8d7b", // indirizzo GovFactory su Sepolia
  pollHub: "0x9b3239B4b1714c6ba7DAFAeca17D230FaFa31a28", // indirizzo PollHub su Sepolia
};