// Indirizzi dei contratti deployati — compila DOPO il deploy (lo fai tu in autonomia),
// poi committa e fai push: il sito pubblico li usa in automatico (niente admin online).
//
// Metti SOLO `bootstrap` (consigliato: il sito ricava Router e Factory da lì)
// OPPURE `router` + `factory`. Lascia stringhe vuote se non ancora deployato.
const CONFIG = {
  bootstrap: "", // es. "0xABC...": indirizzo di SystemBootstrap sulla rete pubblica (Sepolia)
  router: "",
  factory: "",
};
