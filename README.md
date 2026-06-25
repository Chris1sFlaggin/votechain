# VoteChain

Piattaforma di voto on-chain con deploy rapido via Remix e frontend collegato ai contratti core del sistema.

## Architettura

Il sistema è composto da:

- `SystemBootstrap`: contratto di bootstrap che deploya e collega i moduli principali.
- `GovFactory`: factory per la creazione dei referendum.
- `Referendum`: contratto di singolo referendum con flow commit / reveal.
- `PollHub`: modulo per petition e firme sociali.

## Deploy rapido da Remix

### 1. Apri Remix
Importa o copia il contratto `SystemBootstrap.sol` e compila con Solidity `0.8.35`.

### 2. Compila
Seleziona il compilatore compatibile e compila il contratto `SystemBootstrap`.

### 3. Deploy
Dal pannello **Deploy & Run Transactions**, deploya `SystemBootstrap`.

Questo contratto inizializza automaticamente:

- `GovFactory`
- `PollHub`

### 4. Recupera gli indirizzi core
Dopo il deploy, chiama:

- `addresses()`
- oppure singolarmente `router()`, `factory()`, `pollHub()`

Salva gli indirizzi ottenuti perché servono al frontend.

## Utilizzo base

### Creare un referendum
Usa `GovFactory.createReferendum(...)` passando:

- titolo
- giurisdizione
- lista delle opzioni

### Votazione
Sul contratto `Referendum`:

1. `commit(...)`
2. `setPhase(...)` per passare alla fase successiva
3. `reveal(...)`
4. `close()` / finalizzazione secondo il flow della governance

## Collegare la webapp

La webapp deve conoscere almeno questi address:

- `router`
- `factory`
- `pollHub`


