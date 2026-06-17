# VoteChain — codebase Solidity (Foundry)

Core **on-chain** del sistema di voto referendario. Qui vive la logica: factory,
geofencing, autorizzazione SPID (simulata), commit/reveal, conteggio. Pensato per
essere guidato da un **frontend statico** (ethers.js + wallet, es. MetaMask),
senza backend applicativo.

## Struttura

```
src/
 ├─ SystemBootstrap.sol       # deploy one-click di tutto (ideale per Remix)
 ├─ core/
 │   ├─ Referendum.sol        # referendum i — Fasi 1/2/3 (commit, reveal, close)
 │   └─ GovFactory.sol        # il Governo deploya un Referendum dedicato (new)
 ├─ auth/
 │   ├─ SPIDWalletRouter.sol  # SPID simulato + autorizzazione k_i + geofencing
 │   └─ Roles.sol             # access control minimale (ADMIN, ORACLE) — no OZ
 ├─ crypto/
 │   └─ VoteVerifier.sol      # libreria: digest keccak256(voto,nonce) + verifica()
 ├─ interfaces/
 │   └─ IReferendum.sol       # interfaccia standard del referendum (frontend/factory)
 └─ utils/
     └─ Errors.sol            # custom errors (es. NonceGiaUtilizzato)
test/
 ├─ Referendum.t.sol          # Fasi 1/2/3, geofencing, annullamento voti
 └─ CommitReveal.t.sol        # collisioni hash, unicità nonce, multi-reveal
script/
 └─ DeploySystem.s.sol        # deploy + 2 referendum demo (SPID self-enroll, niente seed)
web/                          # frontend statico (dApp): index.html, app.js, style.css
 └─ vendor/ethers.umd.min.js  # ethers v6 vendorizzato (sito self-contained)
remix/
 └─ VotingSystem.flat.sol     # tutti i contratti in un file solo (incolla in Remix)
.github/workflows/
 ├─ test.yml                  # CI Foundry (fmt + build + test)
 └─ pages.yml                 # deploy automatico di web/ su GitHub Pages
```

## Ciclo di vita (in `Referendum.sol`)

- **Fase 1 — Voting**: solo `commit(digest)` con `digest = keccak256(voto, nonce)`.
  `verifica()` rifiuta un digest già presente nel dominio del referendum →
  ogni nonce è univoco. Rivoto consentito (nuovo nonce), conta solo l'ultimo.
  **Nessun reveal qui**: prima dello spoglio non esiste alcun conteggio.
- **Fase 2 — Tally (spoglio)**: niente nuovi digest; **si apre il `reveal`**.
- **`reveal(voto, nonce)`** (solo Fase 2): pubblica il voto **in chiaro in ogni
  caso**; vale l'ultimo reveal; il flag `matches` è solo per la UX.
- **Fase 3 — Closed**: `close()` conteggia on-chain, per ogni wallet, l'ultimo
  reveal **se** `keccak256(ultimoVoto, ultimoNonce) == ultimoDigest`. Gli esiti
  sono visibili **solo da qui** (prima restano sigillati anche nella UI).

## SPID simulato pensato per il sito statico

SPID reale è off-chain (IdP accreditato): non gira in una pagina statica. Qui è
**proiettato on-chain** in modo che un frontend statico basti, con un'identità
**fittizia auto-creata** (nessun profilo preimpostato):

1. il cittadino crea un'identità SPID finta dal **proprio wallet** `k_i` (MetaMask):
   `simulatedSpidLogin(giurisdizione)` → il wallet viene autorizzato per la
   giurisdizione scelta;
2. **privacy (PoC)**: nome, cognome e codice fiscale sono solo a video, **non
   vengono inviati on-chain né salvati né mostrati**. On-chain finisce **solo la
   giurisdizione** scelta — nessun dato personale, nemmeno uno pseudonimo;
3. il **geofencing** è applicato on-chain: `Referendum.commit` chiama
   `router.canVote(msg.sender, giurisdizione)`.

> ⚠️ PoC: `simulatedSpidLogin` si fida del chiamante (chiunque può auto-iscrivere
> una giurisdizione). In produzione l'autorizzazione la scriverebbe un
> oracolo off-chain dopo una vera asserzione SPID, vincolando la giurisdizione
> all'identità verificata. Vedi nota in cima a `SPIDWalletRouter.sol`.

## Build · Test · Deploy

```bash
# build
forge build

# test (28 test: fasi, reveal solo in spoglio, geofencing, unicità nonce, multi-reveal)
forge test -vv

# deploy locale
anvil &                                   # nodo EVM locale
forge script script/DeploySystem.s.sol \
     --rpc-url http://127.0.0.1:8545 \
     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
     --broadcast
# stampa gli indirizzi di SPIDWalletRouter / GovFactory / PollHub / Referendum

# deploy su Sepolia (serve una chiave con ETH di test + un RPC)
export SEPOLIA_RPC="https://sepolia.infura.io/v3/<API_KEY>"
forge script script/DeploySystem.s.sol \
     --rpc-url "$SEPOLIA_RPC" --private-key 0x<chiave-con-ETH-di-test> --broadcast
# poi incolla gli indirizzi stampati in web/config.js (router/factory/pollHub),
# oppure deploya SystemBootstrap da Remix e incolla solo `bootstrap`.
```

## Frontend statico (`web/`)

dApp completa, **senza backend applicativo**: il wallet (MetaMask) firma, la
catena fa il resto. Include login SPID simulato, voto (commit), reveal, conteggio
e console governo. Avvio end-to-end locale:

```bash
# 1. nodo EVM locale (raggiungibile anche dal telefono in LAN)
anvil --host 0.0.0.0

# 2. deploy + seeding (in un secondo terminale)
forge script script/DeploySystem.s.sol --rpc-url http://127.0.0.1:8545 \
     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast

# 3. servi il sito statico
cd web && python3 -m http.server 8081 --bind 0.0.0.0
# apri http://localhost:8081 (o http://<IP-LAN>:8081 dal telefono)
```

In MetaMask: aggiungi la rete anvil (RPC `http://127.0.0.1:8545`, chainId
`31337`) e importa una chiave anvil. La chiave **account 0** è il governo (può
emanare/gestire); le altre sono elettori. Gli indirizzi di `SPIDWalletRouter` e
`GovFactory` sono già precompilati nel pannello *Configurazione* (default di un
anvil appena avviato); altrimenti incolla quelli stampati dallo script.

Le chiamate che il frontend fa ai contratti (identiche all'e2e provato con
`cast`):

```js
await router.simulatedSpidLogin("Italia");   // self-enroll (solo giurisdizione on-chain)
const vote   = ethers.encodeBytes32String("si");
const digest = ethers.solidityPackedKeccak256(["bytes32","string"], [vote, "tramonto-42"]);
await referendum.commit(digest);             // Fase 1 (commit)
await referendum.setPhase(2);                // governo: apre lo spoglio
await referendum.reveal(vote, "tramonto-42");// Fase 2 (reveal solo qui)
await referendum.close();                    // governo: conteggio ufficiale
```

Letture (stato, opzioni, risultati, conteggio provvisorio) via `IReferendum` ed
eventi `Committed`/`Revealed`/`Finalized`.

## Esecuzione in Remix IDE

Senza installare nulla, su <https://remix.ethereum.org>:

1. **Nuovo file** → incolla il contenuto di `remix/VotingSystem.flat.sol` (tutti i
   contratti in un file solo, già appiattito con `forge flatten`).
2. **Solidity Compiler** → versione `0.8.x` → *Compile*.
3. **Deploy & Run** → Environment:
   - *Remix VM* per provare offline, oppure
   - *Injected Provider — MetaMask* per deployare su **Sepolia** (serve un po' di ETH di test).
4. Deploya **`SystemBootstrap`** (un clic): crea Router + Factory + PollHub, ti rende
   ADMIN/ORACLE e governo di Italia e San Marino, e registra anche un **secondo
   wallet governativo fisso** (`EXTRA_GOV = 0x22a2…834B54`).
5. Espandi `SystemBootstrap` → leggi `router()` e `factory()` (o `addresses()`).
6. *At Address* su `GovFactory` (indirizzo `factory()`) → `createReferendum("Titolo","Italia",["0x7369…","0x6e6f…"])`
   (le opzioni sono `bytes32`: usa *string → bytes32* o `cast format-bytes32-string`).
7. Da un altro account: *At Address* su `SPIDWalletRouter` → `simulatedSpidLogin("Italia")`
   (identità fittizia, **nessun dato personale on-chain**), poi `commit` (Fase 1) e,
   dopo che il governo apre lo spoglio, `reveal` (Fase 2) sul `Referendum`.

I 28 test girano con Foundry (`forge test`), non in Remix (usano `forge-std`).

## Deploy su GitHub Pages

Il frontend `web/` è completamente statico → si pubblica su GitHub Pages.

1. Porta la cartella `votechain/` su un repo GitHub (è già un repo git con `forge init`):
   `git add -A && git commit -m "votechain" && git push`.
2. Repo → **Settings → Pages → Source: GitHub Actions**. Il workflow
   `.github/workflows/pages.yml` pubblica `web/` a ogni push su `main`/`master`.
3. Deploya i contratti **su Sepolia** (via Remix, vedi sopra) e annota
   l'indirizzo di `SystemBootstrap`.
4. Apri il sito pubblicato, in **⚙️ Configurazione** incolla l'indirizzo di
   `SystemBootstrap` e premi **Carica** (ricava Router+Factory, salvati nel
   browser). In MetaMask resta selezionata Sepolia.

> GitHub Pages serve solo file statici (niente backend): coerente con l'idea che
> tutta la logica sta on-chain e l'unico "off-chain" è la simulazione SPID, qui
> ridotta a una chiamata on-chain (`simulatedSpidLogin`).

## Requisiti spec → dove

| Requisito | Dove |
|---|---|
| Un contratto per referendum + factory | `GovFactory.createReferendum` → `new Referendum` |
| Geofencing (voto solo nella propria giurisdizione) | `SPIDWalletRouter.canVote` in `Referendum.commit` |
| Wallet `k_i` con accesso limitato al referendum | wallet = `msg.sender`, autorizzato per giurisdizione via Router |
| `digest = keccak256(voto, nonce)` | `VoteVerifier.digest` |
| `verifica()` unicità del digest | `VoteVerifier.verifica` + `usedDigest` in `Referendum.commit` |
| Rivoto con nonce nuovo, vale l'ultimo | `Referendum.commit` (lastDigest) |
| Reveal in chiaro in ogni caso, **solo Fase 2 (spoglio)**, multi-reveal | `Referendum.reveal` (gate su `Phase.Tally`) |
| Conteggio differito alla chiusura | `Referendum.close` |
| Esiti sigillati fino alla chiusura | reveal solo in spoglio + UI mostra le barre solo se `finalized` |
| Nessun dato personale on-chain (solo giurisdizione) | `SPIDWalletRouter` (niente `cfHash`) |
| Ruoli Governo/Oracolo/Admin | `Roles.sol` + registrazioni nel Router |
| Secondo wallet governativo fisso | `SystemBootstrap.EXTRA_GOV` (Italia + San Marino) |
| Custom errors | `Errors.sol` |
