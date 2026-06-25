# VoteChain

Proof of Concept di un sistema di voto **decentralizzato on-chain**: referendum
istituzionali (commit–reveal, voto segreto fino allo spoglio) e raccolte firme con
cauzione anti-spam. Tutta la logica vive negli smart contract Solidity; il frontend
è una dApp **statica** (ethers.js + MetaMask), **senza backend**.

> 📄 Per la trattazione tecnica completa vedi il paper: **[VoteChain.pdf](VoteChain.pdf)**.

**Lo Stato è il deployer.** Chi fa il deploy dei contratti diventa il governo del
proprio sistema: emette i referendum e ne guida le fasi (Votazione → Spoglio →
Chiuso), e valuta le proposte di legge. Un secondo governo fisso è cablato on-chain
(`0x22a2bc6E24FBa136023A126560E2D2490A834B54`). I cittadini interagiscono col solo
wallet: un voto/una firma a testa.

Due contratti, deployati separatamente (il deployer di ciascuno è il governo):

- `src/referendum.sol` — `GovFactory` + `Referendum` (commit–reveal)
- `src/social.sol` — `PollHub` (raccolte firme: cauzione, timeout, esito 100% / 50%)

## Demo live (Sepolia testnet)

- Sito: **https://chris1sflaggin.it/votechain**
- Codice: **https://github.com/chris1sflaggin/votechain**

Contratti già deployati su Sepolia (precompilati in `web/config.js`):

| Contratto | Indirizzo |
|---|---|
| GovFactory | `0x65669485cED109768dB843E955f6b455c04D20e4` |
| PollHub | `0xFb0a81F49527AEAc375F9b253ae20aB8E5a35AdF` |

Per usarla: installa **MetaMask**, passa alla rete **Sepolia** (il sito te lo
propone) e prendi un po' di ETH di test da un faucet. Connetti il wallet: il wallet
che ha fatto il deploy (o il secondo gov cablato) vede i **pannelli governo**; ogni
altro wallet è un **cittadino** che vota nei referendum e firma le proposte.

## Esecuzione in locale (anvil)

```bash
# 1. nodo EVM locale
anvil

# 2. deploy (in un altro terminale) — il deployer diventa il governo.
#    Crea anche 2 referendum demo e stampa gli indirizzi.
forge script script/DeploySystem.s.sol --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast

# 3. incolla gli indirizzi stampati (GovFactory, PollHub) in web/config.js
#    e imposta chainId: 31337  

# 4. servi il frontend statico
cd web && python3 -m http.server 8081
# apri http://localhost:8081
```

In MetaMask aggiungi la rete anvil (RPC `http://127.0.0.1:8545`, chainId `31337`) e
importa una chiave di anvil. L'**account 0** (lo stesso che esegue lo script) è il
governo; gli altri account sono elettori.

## Test

```bash
forge test
```

42 test Foundry: fasi commit–reveal, reveal col solo nonce, unicità del nonce
per-wallet, conteggio differito, raccolte firme (cauzione minima, timeout, esito
100%/50%, claim anticipato al quorum) e il secondo governo fisso.
