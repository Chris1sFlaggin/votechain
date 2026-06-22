/* VoteChain dApp — frontend statico (GitHub Pages + Sepolia). Solo wallet, niente backend.
   Indirizzi in config.js. Ruoli mutuamente esclusivi: l'account registrato come Governo
   on-chain vede SOLO il pannello Governo; tutti gli altri sono cittadini e votano. */

const PHASES = ["Configurazione", "Votazione aperta", "Spoglio in corso", "Referendum chiuso"];
const LABELS = { si: "Sì", no: "No", bianca: "Scheda Bianca" };
const CFG = (typeof CONFIG !== "undefined") ? CONFIG : { factory: "", pollHub: "", chainId: 11155111 };

const FACTORY_ABI = [
  "function government() view returns (address)",
  "function createReferendum(string, string[]) returns (address)",
  "function getReferenda() view returns (address[])",
];
const REF_ABI = [
  "function title() view returns (string)",
  "function government() view returns (address)",
  "function phase() view returns (uint8)",
  "function finalized() view returns (bool)",
  "function getOptions() view returns (bytes32[])",
  "function getLabels() view returns (string[])",
  "function getVoters() view returns (address[])",
  "function result(bytes32) view returns (uint256)",
  "function committedCount() view returns (uint256)",
  "function revealedCount() view returns (uint256)",
  "function usedNonce(address, bytes32) view returns (bool)",
  "function ballots(address) view returns (bytes32 lastDigest, bool committed, bool confirmed, bytes32 vote, string nonce)",
  "function commit(bytes32, bytes32)",
  "function reveal(string)",
  "function setPhase(uint8)",
  "function close()",
];
const POLLHUB_ABI = [
  "function government() view returns (address)",
  "function createPetition(string, string) payable returns (uint256)",
  "function sign(uint256)",
  "function claim(uint256)",
  "function petitionsCount() view returns (uint256)",
  "function getPetition(uint256) view returns (address creator, string title, string description, uint128 stake, uint64 signatureCount, bool approved, bool decided, bool claimed)",
  "function hasSignedPetition(uint256, address) view returns (bool)",
  "function decide(uint256, bool)",
  "function decision(uint256) view returns (bool decided, bool approved, address by)",
];

const S = { provider: null, signer: null, account: null, factory: null, pollHub: null };
const ADDR = { factory: "", pollHub: "" };
let IS_GOV = false;
let GOV_ADDR = "";

const $ = (id) => document.getElementById(id);
const labelOf = (id) => LABELS[id] || id;
// Decode difensivo: un'opzione non-decodificabile non deve far saltare l'intera lista.
const decodeOpt = (b) => { try { return ethers.decodeBytes32String(b); } catch { return String(b); } };
// optionId è già un bytes32 (id unico letto da getOptions); il digest nasconde il voto.
const digestOf = (optionId, nonce) =>
  ethers.solidityPackedKeccak256(["bytes32", "string"], [optionId, nonce]);
// impegno sul nonce, indipendente dal voto: l'unicità è su questo → nonce riusato = errore
// qualunque sia il voto (mentre il digest tiene nascosto il voto fino al reveal).
const nonceTagOf = (nonce) => ethers.solidityPackedKeccak256(["string"], [nonce]);

function avatar(addr) {
  const h = addr.toLowerCase();
  const a = parseInt(h.slice(2, 8), 16) % 360, b = parseInt(h.slice(8, 14), 16) % 360;
  return `<span class="ava" style="background:linear-gradient(135deg,hsl(${a},72%,58%),hsl(${b},72%,46%))"></span>`;
}

function toast(msg, kind = "ok") {
  const t = $("toast");
  t.textContent = msg; t.className = `toast toast--${kind}`;
  setTimeout(() => t.classList.add("hidden"), 5000);
}
async function tx(promise, ok) {
  try { toast("Transazione inviata…", "wait"); const r = await promise; await r.wait(); toast(ok, "ok"); return true; }
  catch (e) { toast(reason(e), "err"); return false; }
}
function reason(e) {
  const s = e?.shortMessage || e?.reason || e?.message || String(e);
  const m = s.match(/(NonceGiaUtilizzato|GovernmentCannotVote|NotGovernment|VotingNotOpen|RevealClosed|NoVote|CloseOnlyFromTally|AlreadyFinalized|EmptyOptions)/);
  return m ? `Errore contratto: ${m[1]}` : s;
}

// ------------------------------------------------------------------ wallet
async function connect() {
  if (!window.ethereum) return toast("MetaMask non rilevato: installa l'estensione.", "err");
  S.provider = new ethers.BrowserProvider(window.ethereum);
  await S.provider.send("eth_requestAccounts", []);
  S.signer = await S.provider.getSigner();
  S.account = await S.signer.getAddress();
  const net = await S.provider.getNetwork();
  window.ethereum.on?.("accountsChanged", () => location.reload());
  window.ethereum.on?.("chainChanged", () => location.reload());
  if (CFG.chainId && Number(net.chainId) !== Number(CFG.chainId)) {
    toast(`Rete sbagliata (chain ${net.chainId}). Passa a Sepolia.`, "err");
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x" + Number(CFG.chainId).toString(16) }] });
    } catch { /* l'utente cambia a mano; chainChanged ricarica */ }
    return;
  }
  $("connect").textContent = "Connesso";
  const okAddr = await resolveAddresses();
  if (!okAddr || !initContracts()) { toast("Sistema non configurato per questa rete (config.js).", "err"); return; }
  await refresh();
  startExplorer().catch(() => {}); // esplora-chain live (non blocca il resto)
  renderChainGate();
  if (document.body.dataset.screen === "social") renderSocial();
}
$("connect").onclick = connect;
$("connectHero").onclick = connect;
$("connectSocial").onclick = connect;
$("connectChain").onclick = connect;

async function resolveAddresses() {
  if (ethers.isAddress(CFG.factory)) {
    ADDR.factory = CFG.factory;
    ADDR.pollHub = ethers.isAddress(CFG.pollHub) ? CFG.pollHub : "";
    return true;
  }
  return false;
}
function initContracts() {
  if (!ethers.isAddress(ADDR.factory)) return false;
  S.factory = new ethers.Contract(ADDR.factory, FACTORY_ABI, S.signer || S.provider);
  S.pollHub = ethers.isAddress(ADDR.pollHub) ? new ethers.Contract(ADDR.pollHub, POLLHUB_ABI, S.signer || S.provider) : null;
  return true;
}

// --------------------------------------------------------------- ruoli + UI
async function refresh() {
  if (!S.account || !S.factory) return;
  try { GOV_ADDR = await S.factory.government(); } catch { GOV_ADDR = ""; }
  IS_GOV = !!GOV_ADDR && GOV_ADDR.toLowerCase() === S.account.toLowerCase();
  renderIdentity();
  gateAreas();
  await renderReferenda();
}

function renderIdentity() {
  const role = IS_GOV
    ? `<span class="role role--gov">Governo</span>`
    : `<span class="role role--cit">Cittadino</span>`;
  $("identity").innerHTML = `${avatar(S.account)}<span class="addr">${S.account.slice(0, 6)}…${S.account.slice(-4)}</span>${role}`;
  $("identity").classList.remove("hidden");
}

function gateAreas() {
  $("landing").classList.add("hidden");
  $("voteSection").classList.remove("hidden");
  if (IS_GOV) {
    $("govArea").classList.remove("hidden");
    $("citizenArea").classList.add("hidden");
  } else {
    $("citizenArea").classList.remove("hidden");
    $("govArea").classList.add("hidden");
  }
}

// L'identità SPID NON è più globale: si crea per-referendum, dal riquadro di ciascun
// referendum (vedi card()/wireCards). Niente login SPID globale qui.

// ----------------------------------------------------------------- governo
$("createRef").onclick = async () => {
  const title = $("newTitle").value.trim();
  const opts = $("newOpts").value.split("\n").map((s) => s.trim()).filter(Boolean);
  if (!title || opts.length < 2) return toast("Titolo + almeno 2 opzioni.", "err");
  // le opzioni vanno come testo: il contratto assegna a ognuna un id UNICO (anche se il testo è uguale)
  const ok = await tx(S.factory.createReferendum(title, opts), `Referendum «${title}» emanato.`);
  if (ok) { $("newTitle").value = ""; $("newOpts").value = ""; await refresh(); }
};

// ------------------------------------------------------------- referenda
async function renderReferenda() {
  const box = $("referenda");
  let addrs = [];
  try { addrs = await S.factory.getReferenda(); } catch (e) { box.innerHTML = `<p class="muted">Impossibile leggere i referendum: ${reason(e)}</p>`; return; }
  if (!addrs.length) {
    box.innerHTML = `<div class="empty">${IS_GOV ? "Nessun referendum: emanane uno dal pannello qui sopra." : "Nessun referendum ancora pubblicato."}</div>`;
    return;
  }
  // Render resiliente: un referendum illeggibile mostra una card d'errore, non blocca gli altri.
  const cards = await Promise.all(addrs.map((a) => card(a).catch((e) => cardError(a, e))));
  box.innerHTML = cards.join("");
  wireCards();
}

function cardError(addr, e) {
  return `<article class="ref-card ref-card--err">
    <div class="ref-card__top"><span class="phase">—</span></div>
    <h3>Referendum non leggibile</h3>
    <p class="ref-card__meta">${addr.slice(0, 10)}… · ${reason(e)}</p>
  </article>`;
}

async function card(addr) {
  const c = new ethers.Contract(addr, REF_ABI, S.signer || S.provider);
  const [title, gov, phaseRaw, finalized, ids, labels, committed, revealed] = await Promise.all([
    c.title(), c.government(), c.phase(), c.finalized(), c.getOptions(), c.getLabels(),
    c.committedCount(), c.revealedCount(),
  ]);
  const phase = Number(phaseRaw);
  // opzione = { id univoco (per il voto), label (testo mostrato, può ripetersi) }
  const options = ids.map((id, i) => ({ id, label: labels[i] ?? decodeOpt(id) }));
  const isGovOfThis = S.account && gov.toLowerCase() === S.account.toLowerCase();
  const me = await c.ballots(S.account).catch(() => null);

  // SEGRETEZZA: gli esiti sono sigillati finché il referendum non è chiuso (close()).
  let results;
  if (finalized) {
    const counts = await Promise.all(ids.map((id) => c.result(id).then(Number).catch(() => 0)));
    const total = counts.reduce((a, b) => a + b, 0);
    results = `<div class="bars">` + options.map((o, i) => {
      const v = counts[i], pct = total ? Math.round((100 * v) / total) : 0;
      return `<div class="bar"><div class="bar__l"><span>${labelOf(o.label)}</span><b>${v}${total ? ` · ${pct}%` : ""}</b></div>
        <div class="bar__t"><div class="bar__f" style="width:${pct}%"></div></div></div>`;
    }).join("") + `</div>`;
  } else {
    results = `<div class="sealed">Esiti visibili solo dopo lo spoglio · opzioni: ${options.map((o) => labelOf(o.label)).join(" · ")}</div>`;
  }

  let actions = "";
  if (IS_GOV && isGovOfThis) {
    actions = `<div class="gov-ctl">
      <button class="btn btn--sm" data-act="phase" data-ref="${addr}" data-p="2" ${phase !== 1 ? "disabled" : ""}>Avvia spoglio</button>
      <button class="btn btn--sm btn--gov" data-act="close" data-ref="${addr}" ${phase !== 2 ? "disabled" : ""}>Chiudi e conta</button>
    </div>`;
  } else if (!IS_GOV) {
    // voto aperto: qualsiasi wallet vota in fase di Votazione
    if (phase === 1) actions += voteForm(addr, options);
    // reveal solo in spoglio e finché NON confermato
    if (phase === 2 && me && me.committed && !me.confirmed) actions += revealForm(addr);
  }

  const status = me && me.committed
    ? `<span class="pill ${me.confirmed ? "pill--ok" : ""}">${me.confirmed ? "confermato" : "votato"}</span>` : "";

  return `<article class="ref-card">
    <div class="ref-card__top"><span class="phase phase--${phase}">${PHASES[phase]}</span>${status}</div>
    <h3>${title}</h3>
    <p class="ref-card__meta">commit ${committed} · reveal ${revealed} · ${finalized ? "esito ufficiale" : "spoglio non concluso"}</p>
    ${results}
    ${actions}
  </article>`;
}


function voteForm(addr, options) {
  const radios = options.map((o, i) =>
    `<label class="opt"><input type="radio" name="v-${addr}" value="${o.id}" ${i === 0 ? "checked" : ""}><span>${labelOf(o.label)}</span></label>`).join("");
  return `<form class="act" data-vote="${addr}">
    <div class="opts">${radios}</div>
    <div class="act__row">
      <input type="password" placeholder="nonce segreto" data-n="1" minlength="3" required>
      <input type="password" placeholder="ripeti nonce" data-n="2" minlength="3" required>
      <button class="btn btn--primary btn--sm">Vota</button>
    </div>
  </form>`;
}
function revealForm(addr) {
  return `<form class="act" data-reveal="${addr}">
    <span class="act__lbl">Conferma il voto col tuo nonce (il voto lo deduce la blockchain)</span>
    <div class="act__row">
      <input type="password" placeholder="il tuo nonce" data-rn minlength="3" required>
      <button class="btn btn--sm">Conferma voto</button>
    </div>
  </form>`;
}

function wireCards() {
  document.querySelectorAll("[data-vote]").forEach((f) => f.onsubmit = async (e) => {
    e.preventDefault();
    const addr = f.dataset.vote;
    const opt = f.querySelector(`input[name="v-${addr}"]:checked`).value;
    const n1 = f.querySelector('[data-n="1"]').value, n2 = f.querySelector('[data-n="2"]').value;
    if (n1 !== n2) return toast("I due nonce non coincidono.", "err");
    const c = new ethers.Contract(addr, REF_ABI, S.signer);
    const d = digestOf(opt, n1);
    const nt = nonceTagOf(n1);
    if (await c.usedNonce(S.account, nt)) return toast("Hai già usato questo nonce in questo referendum (con qualsiasi voto): scegline un altro.", "err");
    if (await tx(c.commit(d, nt), "Voto registrato sulla blockchain.")) await refresh();
  });
  document.querySelectorAll("[data-reveal]").forEach((f) => f.onsubmit = async (e) => {
    e.preventDefault();
    const addr = f.dataset.reveal;
    const nonce = f.querySelector("[data-rn]").value;
    const c = new ethers.Contract(addr, REF_ABI, S.signer);
    if (await tx(c.reveal(nonce), "Conferma inviata.")) {
      const b = await c.ballots(S.account);
      toast(b.confirmed ? "Voto confermato: scheda valida." : "Nonce errato: nessun voto corrisponde, riprova.", b.confirmed ? "ok" : "err");
      await refresh();
    }
  });
  document.querySelectorAll('[data-act="phase"]').forEach((b) => b.onclick = async () => {
    const c = new ethers.Contract(b.dataset.ref, REF_ABI, S.signer);
    if (await tx(c.setPhase(Number(b.dataset.p)), "Spoglio avviato.")) await refresh();
  });
  document.querySelectorAll('[data-act="close"]').forEach((b) => b.onclick = async () => {
    const c = new ethers.Contract(b.dataset.ref, REF_ABI, S.signer);
    if (await tx(c.close(), "Referendum chiuso: conteggio ufficiale on-chain.")) await refresh();
  });
}


// ============================================================ ESPLORA CHAIN (live)
// Ascolta gli eventi dei NOSTRI contratti su Sepolia e li traduce in linguaggio umano:
// cosa è successo, quali dati restano davvero on-chain, perché. Dà l'idea della blockchain.
const escapeHtml = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

const EXPLORER_IFACE = new ethers.Interface([
  "event ReferendumCreated(address indexed referendum, address indexed government, string title)",
  "event Committed(address indexed voter, bytes32 digest, uint32 revision)",
  "event Revealed(address indexed voter, string vote, string nonce, bool matches)",
  "event PhaseChanged(uint8 phase)",
  "event Finalized(uint256 valid, uint256 nullified)",
  "event PetitionCreated(uint256 indexed id, address indexed creator, string title, uint128 stake)",
  "event Signed(uint256 indexed id, address indexed signer, uint64 totalSignatures)",
  "event PetitionDecided(uint256 indexed id, address indexed government, bool approved)",
  "event StakeClaimed(uint256 indexed id, address indexed creator, uint128 amount)",
]);
const PHASE_NAME = ["Configurazione", "Votazione", "Spoglio", "Chiuso"];
const shortA = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—");
const shortH = (h) => (h ? `${h.slice(0, 10)}…` : "—");

// nome evento -> come raccontarlo a un umano
const EVT_META = {
  ReferendumCreated: {
    ico: "", kind: "create", title: "Referendum emanato",
    sum: (a) => `«${a.title}»`,
    why: "Il governo ha pubblicato un nuovo contratto-referendum: da ora esiste in modo permanente e chiunque può verificarne regole ed esiti. Nessuno può cancellarlo.",
    data: (a) => [["Contratto", shortA(a.referendum)], ["Governo", shortA(a.government)], ["Titolo", a.title]],
  },
  Committed: {
    ico: "", kind: "commit", title: "Voto segreto (commit)",
    sum: (a) => `impronta del voto depositata · revisione ${a.revision}`,
    why: "Il cuore del voto segreto: viene salvato solo keccak256(voto, nonce), un'impronta che NON rivela la scelta. Il voto è già registrato e immutabile, ma resta nascosto fino allo spoglio.",
    data: (a) => [["Elettore", shortA(a.voter)], ["Impronta (hash)", shortH(a.digest)], ["Revisione", String(a.revision)]],
  },
  Revealed: {
    ico: "", kind: "reveal", title: "Voto rivelato (spoglio)",
    sum: (a) => `${a.matches ? labelOf(a.vote) : "nonce errato"} — ${a.matches ? "valido " : "nessun voto "}`,
    why: "Durante lo spoglio l'elettore manda solo il nonce: il contratto prova ogni opzione e trova quale combacia col digest depositato. Chiunque può verificare il conteggio. Un nonce errato non conferma nulla (ritentabile).",
    data: (a) => [["Elettore", shortA(a.voter)], ["Voto dedotto", a.matches ? labelOf(a.vote) : "—"], ["Nonce", a.nonce], ["Confermato?", a.matches ? "sì" : "no"]],
  },
  PhaseChanged: {
    ico: "", kind: "phase", title: "Cambio fase",
    sum: (a) => `→ ${PHASE_NAME[Number(a.phase)] ?? a.phase}`,
    why: "Il governo fa avanzare il ciclo di vita del referendum (Votazione → Spoglio → Chiuso). Ogni passaggio è una transazione tracciata: la sequenza non può essere falsificata.",
    data: (a) => [["Nuova fase", PHASE_NAME[Number(a.phase)] ?? String(a.phase)]],
  },
  Finalized: {
    ico: "", kind: "final", title: "Spoglio concluso",
    sum: (a) => `${a.valid} voti validi · ${a.nullified} nulli`,
    why: "Il referendum è chiuso: il conteggio ufficiale è stato calcolato dal contratto stesso e non è più modificabile. Gli esiti diventano pubblici e definitivi.",
    data: (a) => [["Voti validi", String(a.valid)], ["Voti nulli", String(a.nullified)]],
  },
  PetitionCreated: {
    ico: "", kind: "poll", title: "Raccolta firme creata",
    sum: (a) => `«${a.title}» · cauzione ${ethers.formatEther(a.stake)}Ξ`,
    why: "Un cittadino ha avviato una raccolta firme depositando una cauzione (anti-spam). La petizione è aperta a tutti: basta firmare con il proprio wallet.",
    data: (a) => [["ID", String(a.id)], ["Creatore", shortA(a.creator)], ["Titolo", a.title], ["Cauzione", `${ethers.formatEther(a.stake)} ETH`]],
  },
  Signed: {
    ico: "", kind: "pollvote", title: "Firma raccolta",
    sum: (a) => `firmato · totale ${a.totalSignatures}`,
    why: "Un cittadino ha firmato la petizione. Ogni indirizzo può firmare una sola volta: il contratto impedisce i doppioni.",
    data: (a) => [["Petizione", String(a.id)], ["Firmatario", shortA(a.signer)], ["Firme totali", String(a.totalSignatures)]],
  },
  PetitionDecided: {
    ico: "", kind: "won", title: "Petizione decisa dal governo",
    sum: (a) => `${a.approved ? "APPROVATA" : "RESPINTA"} dal governo`,
    why: "Il governo ha espresso la sua decisione sulla petizione che ha raggiunto la soglia minima di firme. Se approvata, il creatore può reclamare la cauzione.",
    data: (a) => [["Petizione", String(a.id)], ["Governo", shortA(a.government)], ["Decisione", a.approved ? "Approvata" : "Respinta"]],
  },
  StakeClaimed: {
    ico: "", kind: "claim", title: "Cauzione riscattata",
    sum: (a) => `${ethers.formatEther(a.amount)}Ξ restituiti al creatore`,
    why: "Il creatore riprende la cauzione dopo l'approvazione della petizione da parte del governo: un trasferimento di ETH eseguito e tracciato dal contratto, verificabile da chiunque.",
    data: (a) => [["Petizione", String(a.id)], ["Creatore", shortA(a.creator)], ["Importo", `${ethers.formatEther(a.amount)} ETH`]],
  },
};

let EXPLORER_ON = false;
let chainWatch = []; // indirizzi dei nostri contratti da filtrare
const chainSeen = new Set(); // dedupe per txHash:logIndex
let chainItems = []; // eventi decodificati recenti (cap)

async function startExplorer() {
  if (!S.provider) return;
  chainWatch = [ADDR.factory, ADDR.pollHub].filter((a) => ethers.isAddress(a));
  try { chainWatch.push(...(await S.factory.getReferenda())); } catch {}
  const head = await S.provider.getBlockNumber();
  // backfill resiliente: alcuni RPC limitano il range, riprovo via via più corto
  for (const span of [4000, 800, 100, 0]) {
    try { await pullLogs(Math.max(0, head - span), head); break; } catch {}
  }
  if (!EXPLORER_ON) {
    EXPLORER_ON = true;
    S.provider.on("block", (bn) => { pullLogs(bn, bn).catch(() => {}); });
  }
  renderExplorer();
}

async function pullLogs(fromBlock, toBlock) {
  if (!chainWatch.length) return;
  const logs = await S.provider.getLogs({ address: chainWatch, fromBlock, toBlock });
  let added = false, refsChanged = false;
  for (const lg of logs) {
    const key = `${lg.transactionHash}:${lg.index}`;
    if (chainSeen.has(key)) continue;
    let parsed;
    try { parsed = EXPLORER_IFACE.parseLog({ topics: [...lg.topics], data: lg.data }); } catch { parsed = null; }
    if (!parsed || !EVT_META[parsed.name]) continue;
    chainSeen.add(key);
    chainItems.unshift({ block: lg.blockNumber, hash: lg.transactionHash, name: parsed.name, args: parsed.args });
    added = true;
    if (parsed.name === "ReferendumCreated") refsChanged = true;
  }
  if (refsChanged) {
    try { for (const r of await S.factory.getReferenda()) if (!chainWatch.includes(r)) chainWatch.push(r); } catch {}
  }
  if (added) { chainItems = chainItems.slice(0, 40); renderExplorer(); }
}

// un blocco del carosello = una transazione, rappresentata come "blocco" della catena
function blockEl(it) {
  const m = EVT_META[it.name];
  const rows = m.data(it.args)
    .map(([k, v]) => `<div class="evt__kv"><span>${k}</span><b>${escapeHtml(String(v))}</b></div>`).join("");
  return `<article class="block block--${m.kind}" tabindex="0">
    <div class="block__num">blocco #${it.block}</div>
    <div class="block__head"><span class="block__ico">${m.ico}</span><span class="block__title">${m.title}</span></div>
    <div class="block__sum">${escapeHtml(m.sum(it.args))}</div>
    <div class="block__hash">${shortH(it.hash)}</div>
    <div class="block__explain">
      <p class="evt__why">${m.why}</p>
      <div class="evt__data">${rows}</div>
      <a class="evt__link" href="https://sepolia.etherscan.io/tx/${it.hash}" target="_blank" rel="noopener">tx su Etherscan ↗</a>
    </div>
  </article>`;
}

// connettore "a catena" fra un blocco e il successivo
const chainLink = () => `<div class="chain-link" aria-hidden="true"></div>`;

function renderExplorer() {
  const box = $("chainFeed");
  if (!box) return;
  const head = $("chainHead");
  if (head) head.textContent = chainItems.length ? `${chainItems.length} blocchi · in ascolto` : "in ascolto della rete…";
  if (!chainItems.length) {
    box.innerHTML = `<div class="evt-empty">Nessuna transazione ancora. Appena qualcuno crea un'identità, vota, o il governo emana/chiude un referendum, comparirà qui un blocco in tempo reale.</div>`;
    return;
  }
  // carosello orizzontale: dal più vecchio (sinistra) al più recente (destra)
  const ordered = [...chainItems].reverse();
  const rail = ordered.map((it, i) => blockEl(it) + (i < ordered.length - 1 ? chainLink() : "")).join("");
  box.innerHTML = `<div class="chain-rail">${rail}</div>`;
  box.querySelectorAll(".block").forEach((el) => {
    el.onclick = (e) => { if (e.target.closest(".evt__link")) return; el.classList.toggle("evt--open"); };
  });
  // default: mostra il blocco più recente (estrema destra)
  const railEl = box.querySelector(".chain-rail");
  if (railEl) requestAnimationFrame(() => { railEl.scrollLeft = railEl.scrollWidth; });
}

// =================================================================== SOCIAL

// Navigazione a schermate: "access" (scelta), "political" (istituzionale), "social".
function showScreen(which) {
  document.body.dataset.screen = which;
  closeSheet();
  window.scrollTo({ top: 0 });
  if (which === "social") renderSocial();
  if (which === "chain") { renderChainGate(); if (S.provider) startExplorer().catch(() => {}); }
}

const MIN_VOTES = 5; // soglia minima di voti perché un sondaggio "conti" (significatività)

// Social: il governo vede le due pagine (Tutte le raccolte, e Da Approvare).
// I cittadini vedono il feed delle raccolte firme e possono firmare.
function renderSocial() {
  const connected = !!(S.account && S.pollHub);
  $("socialHero").classList.toggle("hidden", connected);
  $("pollFeed").classList.toggle("hidden", connected && IS_GOV);
  $("govAreaSocial").classList.toggle("hidden", !(connected && IS_GOV));
  document.querySelector('[data-snav="create"]').classList.toggle("hidden", IS_GOV);
  if (!connected) return;
  if (IS_GOV) {
    if (!$("govTabPending").onclick) {
      $("govTabPending").onclick = () => { govShow("pending"); renderGovLists(); };
      $("govTabAll").onclick = () => { govShow("all"); renderGovLists(); };
      govShow("pending");
    }
    renderGovLists();
  } else {
    renderPolls();
  }
}

function govShow(tab) {
  $("govTabAll").className = tab === "all" ? "btn btn--primary" : "btn btn--secondary";
  $("govTabPending").className = tab === "pending" ? "btn btn--primary" : "btn btn--secondary";
  $("govAllList").classList.toggle("hidden", tab !== "all");
  $("govPendingList").classList.toggle("hidden", tab !== "pending");
}

// Renderizza liste per il governo (tutte / da approvare)
async function renderGovLists() {
  const allBox = $("govAllList");
  const pendingBox = $("govPendingList");
  if (!S.pollHub) {
    allBox.innerHTML = pendingBox.innerHTML = `<div class="empty">Contratto non disponibile.</div>`;
    return;
  }
  let n;
  try { n = Number(await S.pollHub.petitionsCount()); } catch (e) {
    allBox.innerHTML = pendingBox.innerHTML = `<div class="empty">Errore: ${reason(e)}</div>`;
    return;
  }
  if (!n) {
    allBox.innerHTML = pendingBox.innerHTML = `<div class="empty">Nessuna raccolta firme.</div>`;
    return;
  }

  let allCards = [];
  let pendingCards = [];
  
  for (let id = n - 1; id >= 0; id--) {
    const p = await S.pollHub.getPetition(id).catch(() => null);
    if (!p) continue;
    
    // Tutti
    allCards.push(govCardTemplate(id, p, false));
    
    // Da Approvare (>= MIN_VOTES) e non ancora decisa
    if (Number(p.signatureCount) >= MIN_VOTES && !p.decided) {
      pendingCards.push(govCardTemplate(id, p, true));
    }
  }

  allBox.innerHTML = allCards.length ? allCards.join("") : `<div class="empty">Nessuna raccolta presente.</div>`;
  pendingBox.innerHTML = pendingCards.length ? pendingCards.join("") : `<div class="empty">Nessuna raccolta da approvare.</div>`;
  
  document.querySelectorAll("[data-approve]").forEach(b => b.onclick = async () => {
    const ok = await tx(S.pollHub.decide(Number(b.dataset.approve), true), "Petizione approvata.");
    if(ok) renderGovLists();
  });
  document.querySelectorAll("[data-reject]").forEach(b => b.onclick = async () => {
    const ok = await tx(S.pollHub.decide(Number(b.dataset.reject), false), "Petizione respinta.");
    if(ok) renderGovLists();
  });
}

function govCardTemplate(id, p, isActionable) {
  let badge = "", actions = "";
  if (p.decided) {
    badge = p.approved ? `<span class="won">APPROVATA</span>` : `<span class="pill">Respinta</span>`;
  } else {
    badge = `<span class="prog-pill">${p.signatureCount} firme</span>`;
  }
  
  if (isActionable) {
    actions = `<div style="margin-top:1rem;display:flex;gap:10px;">
      <button class="btn btn--sm btn--gov" data-approve="${id}">Approva</button>
      <button class="btn btn--sm" data-reject="${id}">Respingi</button>
    </div>`;
  }
  
  return `<article class="poll">
    <div class="poll__head">${avatar(p.creator)}<span class="addr">${p.creator.slice(0, 6)}…${p.creator.slice(-4)}</span>
    <span class="poll__stake">cauzione ${ethers.formatEther(p.stake)}Ξ</span>${badge}</div>
    <h3 class="poll__q">${escapeHtml(p.title)}</h3>
    <p style="margin-bottom:1rem;font-size:0.95rem;">${escapeHtml(p.description)}</p>
    ${actions}
  </article>`;
}

function renderChainGate() {
  $("chainConnect").classList.toggle("hidden", !!(S.signer && S.factory));
}
document.querySelectorAll("[data-go]").forEach((b) => (b.onclick = () => showScreen(b.dataset.go)));
// il logo in alto riporta alla scelta della sezione
document.querySelector(".nav .brand").onclick = () => showScreen("access");

// ---- bottom sheet "crea sondaggio" (stile app social) ----
function openSheet() { $("pollSheet").classList.add("open"); }
function closeSheet() { $("pollSheet")?.classList.remove("open"); }
$("pollSheet").onclick = (e) => { if (e.target.id === "pollSheet") closeSheet(); };

// ---- bottom nav social ----
document.querySelectorAll("[data-snav]").forEach((b) => (b.onclick = () => {
  const a = b.dataset.snav;
  document.querySelectorAll(".snav").forEach((s) => s.classList.toggle("is-active", s === b && a !== "create"));
  if (a === "feed") { renderSocial(); window.scrollTo({ top: 0, behavior: "smooth" }); }
  else if (a === "create") {
    if (!S.pollHub) return toast("Connetti il wallet su Sepolia per creare un sondaggio.", "err");
    openSheet();
  } else if (a === "switch") showScreen("access");
}));

$("createPoll").onclick = async () => {
  if (!S.pollHub) return toast("Connetti il wallet su Sepolia.", "err");
  const title = $("petitionTitle").value.trim();
  const desc = $("petitionDesc").value.trim();
  if (!title || !desc) return toast("Titolo e descrizione sono obbligatori.", "err");
  let value;
  try { value = ethers.parseEther(($("pollStake").value || "0").trim()); } catch { return toast("Cauzione non valida.", "err"); }
  if (value <= 0n) return toast("La cauzione deve essere maggiore di 0.", "err");
  
  const ok = await tx(S.pollHub.createPetition(title, desc, { value }), "Raccolta firme pubblicata.");
  if (ok) { $("petitionTitle").value = ""; $("petitionDesc").value = ""; closeSheet(); await renderPolls(); }
};

async function renderPolls() {
  const feed = $("pollFeed");
  if (!S.pollHub) { feed.innerHTML = `<div class="empty">Contratto non disponibile.</div>`; return; }
  let n;
  try { n = Number(await S.pollHub.petitionsCount()); } catch (e) { feed.innerHTML = `<div class="empty">Errore: ${reason(e)}</div>`; return; }
  if (!n) { feed.innerHTML = `<div class="empty">Nessuna raccolta firme. Creane una con il "+" in basso.</div>`; return; }
  
  const ids = [...Array(n).keys()].reverse(); // più recenti in cima
  feed.innerHTML = (await Promise.all(ids.map(pollCard))).join("");
  wirePolls();
}

async function pollCard(id) {
  const p = await S.pollHub.getPetition(id);
  const creator = p.creator, title = p.title, desc = p.description;
  const stake = p.stake, total = Number(p.signatureCount);
  const approved = p.approved, decided = p.decided, claimed = p.claimed;
  
  const hasSigned = await S.pollHub.hasSignedPetition(id, S.account).catch(() => false);
  const isCreator = S.account && creator.toLowerCase() === S.account.toLowerCase();

  let prog, progLabel;
  if (decided) {
    prog = 100;
    progLabel = approved ? "Approvata dal governo" : "Respinta dal governo";
  } else {
    prog = Math.min(100, Math.round((100 * total) / MIN_VOTES));
    progLabel = total >= MIN_VOTES ? `In attesa di decisione` : `${total}/${MIN_VOTES} firme minime`;
  }
  
  let badge = "";
  if (decided) badge = approved ? `<span class="won">APPROVATA</span>` : `<span class="pill">Respinta</span>`;
  else badge = `<span class="prog-pill">${total} firme</span>`;
  
  let claim = "";
  if (isCreator && decided && approved && !claimed) {
    claim = `<button class="btn btn--social poll-claim" data-claim="${id}">Reclama cauzione (${ethers.formatEther(stake)} ETH)</button>`;
  } else if (isCreator && claimed) {
    claim = `<span class="muted" style="display:block;margin-top:10px;">cauzione riscattata</span>`;
  }
  
  const tags = `${isCreator ? '<span class="pill">tua</span>' : ""}${hasSigned ? '<span class="pill pill--ok">hai firmato</span>' : ""}`;
  const dis = (hasSigned || decided) ? "disabled" : "";
  const signBtn = `<button class="btn btn--primary" style="width:100%;margin-top:1rem;" data-pid="${id}" ${dis}>${hasSigned ? 'Hai già firmato' : 'Firma con Wallet'}</button>`;

  return `<article class="poll">
    <div class="poll__head">${avatar(creator)}<span class="addr">${creator.slice(0, 6)}…${creator.slice(-4)}</span>${tags}<span class="poll__stake">cauzione ${ethers.formatEther(stake)}Ξ</span>${badge}</div>
    <h3 class="poll__q">${escapeHtml(title)}</h3>
    <p style="margin-bottom:1rem;font-size:0.95rem;">${escapeHtml(desc)}</p>
    <div class="poll__prog"><div class="poll__progbar"><div style="width:${prog}%"></div></div><span>${progLabel}</span></div>
    ${isCreator ? claim : signBtn}
  </article>`;
}

function wirePolls() {
  document.querySelectorAll("[data-pid]:not([disabled])").forEach((b) => b.onclick = async () => {
    const ok = await tx(S.pollHub.sign(Number(b.dataset.pid)), "Firma registrata con successo.");
    if (ok) await renderPolls();
  });
  document.querySelectorAll("[data-claim]").forEach((b) => b.onclick = async () => {
    const ok = await tx(S.pollHub.claim(Number(b.dataset.claim)), "Cauzione riscattata.");
    if (ok) await renderPolls();
  });
}
