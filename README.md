# VoteChain — Documentazione del Progetto PoC

## Panoramica del Sistema

VoteChain è un Proof of Concept (PoC) per un sistema di votazione elettronica decentralizzato basato su blockchain, progettato per supportare sia referendum che raccolte firme. L’obiettivo primario è garantire la **segretezza del voto**, la **resistenza alla manipolazione** e la **verificabilità pubblica** del processo elettorale, sfruttando le proprietà crittografiche e di immutabilità di una rete blockchain.

Il design architetturale si ispira al meccanismo **commit-reveal**: ogni votante prima pubblica un impegno crittografico (commit) del proprio voto, successivamente lo rivela (reveal) durante la fase di spoglio. Questo schema separa il momento dell’espressione del voto dal momento della sua decodifica, impedendo a chiunque — incluso il governo — di conoscere le intenzioni degli elettori prima della chiusura delle urne.

---

## Attori del Sistema

Il sistema coinvolge due categorie principali di attori istituzionali.

### Il Governo (Deployer)

Il governo è l’entità che **effettua il deploy del contratto** sulla blockchain e ne detiene i privilegi amministrativi. Le sue responsabilità comprendono:

-   Creare e configurare nuovi referendum (titolo, opzioni di voto, durata)
-   Avviare la fase di spoglio al termine del periodo di votazione
-   Chiudere ufficialmente lo spoglio e calcolare i risultati

Il governo non ha accesso ai contenuti dei voti durante la fase di commit, garantendo così che il processo rimanga imparziale fino all’apertura ufficiale delle urne.

### Il Cittadino (Votante)

Nel sistema reale (produzione), il cittadino si autenticherebbe tramite **SPID** (Sistema Pubblico di Identità Digitale), ottenendo un identificatore univoco federato. Nel PoC, questa fase è simulata. Le interazioni del cittadino con il sistema comprendono:

-   Generazione del wallet dedicato al referendum
-   Espressione e modifica del voto (fase di commit)
-   Conferma del voto durante lo spoglio (fase di reveal)

---

## Architettura: Generazione del Wallet per Referendum

Una delle caratteristiche innovative di VoteChain è la creazione di un **wallet monouso per referendum**. Anziché utilizzare un wallet generico del cittadino, viene derivato un indirizzo Ethereum specifico per ogni coppia (cittadino, referendum).

Il processo di derivazione avviene come segue:

seed = hash(SPID\_ID, referendum\_key)

Dove `referendum_key` è una chiave autogenerata dal contratto al momento della creazione del referendum. Da questo seed viene derivato deterministicamente un wallet Ethereum (coppia chiave privata / indirizzo pubblico). Questo meccanismo garantisce che:

1.  Lo stesso cittadino generi sempre lo stesso wallet per lo stesso referendum (riproducibilità)
2.  Il wallet sia inutilizzabile in qualsiasi altro contesto (isolamento)
3.  Non sia possibile correlare l’identità SPID all’indirizzo on-chain senza conoscere entrambi i segreti (anonimizzazione)

---

## Fase 1 — Commit: Espressione del Voto

### Offuscamento dei Valori di Voto

Per impedire l’analisi statistica delle transazioni on-chain, i valori che rappresentano le opzioni di voto (es. `SI`, `NO`) sono mappati a **identificatori opachi generati casualmente per ogni referendum**. Ad esempio:

| Opzione | Valore Opaco (esempio) |
| --- | --- |
| SI | `0x3f7a9c…` |
| NO | `0xb21e04…` |
| ASTENSIONE | `0x9d05fe…` |

Questa mappatura è nota solo al contratto, e viene rigenerata ad ogni referendum, rendendo impossibile dedurre il voto dall’osservazione della transazione.

### Struttura del Commit

Il cittadino sceglie il proprio voto e inserisce un **nonce** (password monouso a sua scelta). Il commit viene costruito come:

commit = hash( voto\_opaco, nonce)

Questo digest viene inviato on-chain tramite una transazione dal wallet dedicato al referendum. Il contratto registra il commit senza poter risalire al voto effettivo, perché non conosce né il nonce né la mappatura invertita del voto opaco in quel momento.

### Modifica del Voto

Il cittadino può **cambiare il proprio voto** prima della chiusura della fase di commit. Per farlo, si ri-autentica con le stesse modalità (SPID + referendum key → wallet), esprime un nuovo voto e sceglie un **nuovo nonce**. Prima di registrare il nuovo commit, il contratto esegue una **funzione di verifica** che:

1.  Recupera tutte le transazioni storiche emesse dal wallet del cittadino per quel referendum
2.  Per ogni transazione, calcola `hash(voto_opaco_X || nonce_proposto)` per tutte le opzioni di voto possibili `X`
3.  Controlla che nessuno dei digest calcolati coincida con il commit della transazione esistente

Se il nuovo nonce non compare in nessuna transazione precedente, il nuovo commit viene accettato e registrato on-chain. Le transazioni di commit precedenti rimangono sulla blockchain ma diventano **irrilevanti** ai fini dello spoglio, poiché non sarà mai rivelato il nonce ad esse associato.

---

## Fase 2 — Reveal: Conferma e Spoglio

### Avvio dello Spoglio

Trascorso il periodo di votazione configurato dal governo, viene invocata la funzione di apertura dello spoglio. Da questo momento i cittadini non possono più modificare il proprio voto e devono procedere alla fase di conferma.

### Conferma del Voto (Reveal)

Ogni cittadino ri-accede al sistema (tramite SPID + referendum key → stesso wallet deterministico) e **pubblica il proprio nonce** in chiaro in una transazione di reveal. Il contratto verifica che:

hash( voto\_dichiarato, nonce\_rivelato) = commit\_registrato

Se la verifica fallisce (nonce errato o voto dichiarato non corrispondente), il cittadino può ripetere la fase di conferma fornendo i dati corretti. Se la verifica ha successo, la transazione di reveal viene accettata e il voto è considerato confermato.

### Conteggio dei Voti

Una volta che tutti i cittadini hanno completato il reveal (o scaduto il termine), il governo invoca la funzione di chiusura dello spoglio. Il conteggio avviene tramite la stessa **funzione di verifica** usata in fase di commit, applicata ora in modalità di lettura aggregata:

Per ogni wallet `i` di cittadino e per ogni opzione di voto `V`:

exists transazione(t\_i) t.c. hash(voto\_opaco(V) , nonce\_rivelato\_i) = commit}(t\_i)  
\]

Se questa condizione è soddisfatta, il voto del cittadino `i` per l’opzione `V` viene conteggiato. Le transazioni di commit precedenti (relative a voti poi modificati) non vengono mai conteggiate, poiché i relativi nonce non sono mai stati pubblicati e non esiste alcun nonce rivelato che le faccia combaciare.

---

## Schema del Flusso Completo

\[Governo\] │ ├─ deploy contratto └─ crea referendum (titolo, opzioni, referendum\_key, durata) │ ▼\[Cittadino\] ─── SPID\_ID + referendum\_key │ ▼ genera wallet dedicato │ sceglie voto + nonce │ commit = hash(voto\_opaco || nonce) ──▶ \[Blockchain\] │ (opzionale) modifica voto con nuovo nonce │ ▼\[Governo\] avvia spoglio │ ▼\[Cittadino\] pubblica nonce in reveal ──────────▶ \[Blockchain\] │ ▼\[Governo\] chiude spoglio → conteggio automatico via funzione verifica

---

## Proprietà di Sicurezza

Il sistema garantisce le seguenti proprietà crittografiche e di sistema:

-   **Segretezza ante-spoglio**: nessuno può conoscere il contenuto dei voti prima del reveal, poiché i commit sono hash non invertibili senza il nonce
-   **Non-correlabilità**: il wallet derivato da SPID + referendum\_key non è riconducibile all’identità reale senza entrambi i segreti
-   **Unicità del voto**: la funzione di verifica impedisce riuso di nonce, garantendo che ogni votante conti esattamente una volta
-   **Resistenza alla coercizione**: il cittadino può cambiare voto liberamente fino alla chiusura del commit, e il voto modificato non lascia tracce collegabili
-   **Immutabilità e auditabilità**: tutte le transazioni sono pubbliche e verificabili su blockchain, ma decodificabili solo con il nonce rivelato

---

## Modulo Raccolta Firme: Proposte dei Cittadini

### Obiettivo e Logica Generale

Il modulo di raccolta firme consente ai cittadini di **avanzare proposte di legge o istanze formali** a un’istituzione, raccogliendo un numero sufficiente di adesioni on-chain per raggiungere il quorum necessario alla presa in carico. Il flusso è deliberatamente più semplice rispetto al referendum, poiché la firma non è segreta: l’atto di sostenere una proposta è pubblico e verificabile.

Tuttavia, per prevenire lo spam di proposte infondate che ingaserebbero la blockchain e l’agenda istituzionale, il sistema introduce un meccanismo di **cauzione anti-spam**: chiunque voglia avanzare una proposta deve bloccare una quantità di token nel contratto. Questa cauzione viene gestita automaticamente dallo smart contract in base all’esito della proposta.

### Ciclo di Vita di una Proposta

**1\. Creazione della Proposta (Proponente)**

Un cittadino autenticato via SPID genera il proprio wallet dedicato alla proposta (stesso meccanismo: `hash(SPID_ID || proposal_key)`). Per avviare la raccolta firme, il proponente invia una transazione che include:

-   Il testo della proposta
-   Un **deposito cauzionale** in token (es. ETH o token di governance), la cui soglia minima è definita dal contratto

La cauzione viene **bloccata (locked) nello smart contract** e non è accessibile né al proponente né al governo fino alla risoluzione della proposta.

**2\. Firma della Proposta (Firmatari)**

Ogni cittadino che vuole aderire accede con il proprio wallet dedicato alla proposta (derivato da `hash(SPID_ID || proposal_key)`) e invia una transazione di firma. A differenza del referendum, la firma è in chiaro: non è richiesto meccanismo commit-reveal perché l’anonimato non è necessario — sostenere una proposta è un atto politico pubblico.

Il contratto tiene traccia di tutti i wallet firmatari e verifica che ciascun wallet abbia firmato al più una volta (unicità garantita dall’isolamento del wallet per proposta).

**3\. Raggiungimento del Quorum**

Alla scadenza del periodo di raccolta, il contratto verifica automaticamente se il numero di firme valide ha raggiunto la soglia (quorum) stabilita al momento della creazione. Esistono due esiti:

| Esito | Condizione | Conseguenza sulla Cauzione |
| --- | --- | --- |
| **Proposta ammessa** | Firme ≥ quorum | La cauzione viene **restituita** al proponente |
| **Proposta respinta** | Firme < quorum | La cauzione viene **trattenuta** (es. devoluta a un fondo comune o bruciata) |

**4\. Valutazione Istituzionale**

Se la proposta raggiunge il quorum, viene formalmente trasmessa all’istituzione (governo). L’istituzione può approvarla, respingerla o trasformarla in referendum. In tutti i casi, la restituzione della cauzione avviene al raggiungimento del quorum e non dipende dall’approvazione politica: il sistema incentiva la presentazione di proposte **con reale consenso popolare**, non necessariamente approvate dal governo.

### Logica Anti-Spam della Cauzione

Il meccanismo della cauzione risolve un problema classico dei sistemi di governance decentralizzata: senza un costo, chiunque potrebbe inondare il sistema con proposte prive di sostegno reale. La cauzione agisce come **segnale di credibilità**:

-   Il proponente ha un incentivo economico a raccogliere firme reali, poiché solo raggiungendo il quorum rientra in possesso della cauzione
-   I firmatari non pagano alcuna cauzione, abbassando la barriera alla partecipazione democratica
-   Il costo di una proposta fallita è interamente a carico del proponente, disincentivando lo spam senza penalizzare i cittadini sostenitori

## Limitazioni del PoC e Sviluppi Futuri

Il presente PoC semplifica o omette alcune componenti presenti nel sistema reale:

| Componente | PoC | Sistema Reale |
| --- | --- | --- |
| Autenticazione | Simulata | SPID (OpenID Connect / SAML) |
| Rete blockchain | Testnet / locale | Rete pubblica o permissioned enterprise |
| Raccolta firme | Schema base | Firma digitale on-chain con verifica legale |
| Chiave di sessione referendum | Generata in-app | HSM governativo con audit log |
| Gestione wallet | Client-side | Secure enclave o MPC wallet |

Tra i miglioramenti previsti per la versione di produzione figurano l’integrazione con l’infrastruttura SPID ufficiale, l’adozione di **zero-knowledge proof** per la verifica dei commit senza rivelare il nonce intermedio, e l’implementazione di un sistema di **threshold decryption** per lo spoglio distribuito che non dipenda dalla singola azione governativa.