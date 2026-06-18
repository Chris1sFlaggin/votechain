/* VoteChain dApp — frontend statico (GitHub Pages + Sepolia). Solo wallet, niente backend.
   Indirizzi in config.js. Ruoli mutuamente esclusivi: l'account registrato come Governo
   on-chain vede SOLO il pannello Governo; tutti gli altri sono cittadini e votano. */

const PHASES = ["Configurazione", "Votazione aperta", "Spoglio in corso", "Referendum chiuso"];
const LABELS = { si: "Sì", no: "No", bianca: "Scheda Bianca" };
const seenJur = new Set(["Italia", "San Marino"]);
const CFG = (typeof CONFIG !== "undefined") ? CONFIG : { bootstrap: "", router: "", factory: "", chainId: 11155111 };

const ROUTER_ABI = [
  "function simulatedSpidLogin(address referendum, string jurisdiction)",
  "function isAuthorized(address, address) view returns (bool)",
  "function jurisdictionOf(address, address) view returns (string)",
  "function canVote(address, address, string) view returns (bool)",
  "function isGovernment(address, string) view returns (bool)",
];
const FACTORY_ABI = [
  "function createReferendum(string, string, bytes32[]) returns (address)",
  "function getReferenda() view returns (address[])",
];
const REF_ABI = [
  "function title() view returns (string)",
  "function jurisdiction() view returns (string)",
  "function government() view returns (address)",
  "function phase() view returns (uint8)",
  "function finalized() view returns (bool)",
  "function getOptions() view returns (bytes32[])",
  "function getVoters() view returns (address[])",
  "function result(bytes32) view returns (uint256)",
  "function committedCount() view returns (uint256)",
  "function revealedCount() view returns (uint256)",
  "function usedNonce(bytes32) view returns (bool)",
  "function ballots(address) view returns (bytes32 lastDigest, bool committed, bool revealed, bytes32 lastVote, string lastNonce)",
  "function commit(bytes32, bytes32)",
  "function reveal(bytes32, string)",
  "function setPhase(uint8)",
  "function close()",
];
const BOOTSTRAP_ABI = ["function addresses() view returns (address, address, address)"];
const POLLHUB_ABI = [
  "function createPoll(string, bytes32[]) payable returns (uint256)",
  "function vote(uint256, bytes32)",
  "function claim(uint256)",
  "function pollsCount() view returns (uint256)",
  "function getPoll(uint256) view returns (address creator, string question, bytes32[] options, uint128 stake, uint64 totalVotes, bool won, bool claimed)",
  "function optionVotes(uint256, bytes32) view returns (uint256)",
  "function hasVoted(uint256, address) view returns (bool)",
];

const S = { provider: null, signer: null, account: null, router: null, factory: null, pollHub: null };
const ADDR = { router: "", factory: "", pollHub: "" };
let GOV_JURS = [];
let IS_GOV = false;

const $ = (id) => document.getElementById(id);
const labelOf = (id) => LABELS[id] || id;
// Decode difensivo: un'opzione non-decodificabile non deve far saltare l'intera lista.
const decodeOpt = (b) => { try { return ethers.decodeBytes32String(b); } catch { return String(b); } };
const digestOf = (voteId, nonce) =>
  ethers.solidityPackedKeccak256(["bytes32", "string"], [ethers.encodeBytes32String(voteId), nonce]);
// impegno sul nonce, indipendente dal voto: l'unicità è su questo → nonce riusato = errore
// qualunque sia il voto (mentre il digest tiene nascosto il voto fino al reveal).
const nonceTagOf = (nonce) => ethers.solidityPackedKeccak256(["string"], [nonce]);
// pseudonimo per-referendum: identità "finta" mostrata a video, derivata da (wallet, referendum).
// Non è on-chain (on-chain c'è solo la giurisdizione); serve solo a far vedere all'utente la sua identità.
const pseudoId = (wallet, ref) =>
  "SPID-" + ethers.solidityPackedKeccak256(["address", "address"], [wallet, ref]).slice(2, 10).toUpperCase();

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
  const m = s.match(/(NonceGiaUtilizzato|OutOfJurisdiction|WalletNotAuthorized|GovernmentCannotVote|NotGovernment|VotingNotOpen|RevealClosed|NoVote|CloseOnlyFromTally|AlreadyFinalized|EmptyOptions)/);
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
  if (!$("socialView").classList.contains("hidden")) await renderPolls();
}
$("connect").onclick = connect;
$("connectHero").onclick = connect;
$("connectSocial").onclick = connect;

async function resolveAddresses() {
  // dal bootstrap (ritorna router, factory, pollHub)
  if (ethers.isAddress(CFG.bootstrap) && S.signer) {
    try {
      const [r, f, ph] = await new ethers.Contract(CFG.bootstrap, BOOTSTRAP_ABI, S.signer).addresses();
      ADDR.router = r; ADDR.factory = f; ADDR.pollHub = ph; return true;
    } catch { /* bootstrap vecchio o non valido: provo gli indirizzi diretti */ }
  }
  if (ethers.isAddress(CFG.router) && ethers.isAddress(CFG.factory)) {
    ADDR.router = CFG.router; ADDR.factory = CFG.factory;
    ADDR.pollHub = ethers.isAddress(CFG.pollHub) ? CFG.pollHub : "";
    return true;
  }
  return false;
}
function initContracts() {
  if (!ethers.isAddress(ADDR.router) || !ethers.isAddress(ADDR.factory)) return false;
  S.router = new ethers.Contract(ADDR.router, ROUTER_ABI, S.signer || S.provider);
  S.factory = new ethers.Contract(ADDR.factory, FACTORY_ABI, S.signer || S.provider);
  S.pollHub = ethers.isAddress(ADDR.pollHub) ? new ethers.Contract(ADDR.pollHub, POLLHUB_ABI, S.signer || S.provider) : null;
  return true;
}

// --------------------------------------------------------------- ruoli + UI
async function refresh() {
  if (!S.account || !S.router) return;
  GOV_JURS = [];
  for (const j of ["Italia", "San Marino"]) {
    try { if (await S.router.isGovernment(S.account, j)) GOV_JURS.push(j); } catch {}
  }
  IS_GOV = GOV_JURS.length > 0;
  renderIdentity();
  gateAreas();
  await renderReferenda();
}

function renderIdentity() {
  const role = IS_GOV
    ? `<span class="role role--gov">🏛 Governo</span>`
    : `<span class="role role--cit">🧑‍💻 Cittadino</span>`;
  $("identity").innerHTML = `${avatar(S.account)}<span class="addr">${S.account.slice(0, 6)}…${S.account.slice(-4)}</span>${role}`;
  $("identity").classList.remove("hidden");
}

function gateAreas() {
  $("landing").classList.add("hidden");
  $("voteSection").classList.remove("hidden");
  $("chainExplorer").classList.remove("hidden");
  if (IS_GOV) {
    $("govArea").classList.remove("hidden");
    $("citizenArea").classList.add("hidden");
    $("govJurs").textContent = GOV_JURS.join(", ");
    $("newJur").innerHTML = GOV_JURS.map((j) => `<option>${j}</option>`).join("");
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
  const jur = $("newJur").value;
  const opts = $("newOpts").value.split("\n").map((s) => s.trim()).filter(Boolean);
  if (!title || opts.length < 2) return toast("Titolo + almeno 2 opzioni.", "err");
  const b32 = opts.map((o) => ethers.encodeBytes32String(o));
  const ok = await tx(S.factory.createReferendum(title, jur, b32), `Referendum «${title}» emanato.`);
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
  updateJurList();
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
  const [title, jur, gov, phaseRaw, finalized, optsRaw, committed, revealed] = await Promise.all([
    c.title(), c.jurisdiction(), c.government(), c.phase(), c.finalized(), c.getOptions(),
    c.committedCount(), c.revealedCount(),
  ]);
  seenJur.add(jur);
  const phase = Number(phaseRaw);
  const options = optsRaw.map(decodeOpt);
  const isGovOfThis = S.account && gov.toLowerCase() === S.account.toLowerCase();
  const me = await c.ballots(S.account).catch(() => null);

  // Identità SPID PER-REFERENDUM (finta): l'autorizzazione esiste solo per (referendum, wallet).
  // Resta accessibile fino alla chiusura (phase 3 = Closed): dopo lo spoglio non si mostra più.
  const authorized = (!IS_GOV && S.account)
    ? await S.router.isAuthorized(addr, S.account).catch(() => false) : false;
  const canVote = authorized
    ? await S.router.canVote(addr, S.account, jur).catch(() => false) : false;
  let identity = "";
  if (authorized && phase !== 3) {
    identity = `<div class="ident">🪪 Identità: <code>${pseudoId(S.account, addr)}</code> · 📍 ${jur}
      <span class="ident__exp">valida fino alla chiusura</span></div>`;
  }

  // SEGRETEZZA: gli esiti sono sigillati finché il referendum non è chiuso (close()).
  // Prima della chiusura non si mostra nessun conteggio (niente exit-poll on-chain in UI).
  let results;
  if (finalized) {
    const counts = await Promise.all(optsRaw.map((o) => c.result(o).then(Number).catch(() => 0)));
    const total = counts.reduce((a, b) => a + b, 0);
    results = `<div class="bars">` + options.map((o, i) => {
      const v = counts[i], pct = total ? Math.round((100 * v) / total) : 0;
      return `<div class="bar"><div class="bar__l"><span>${labelOf(o)}</span><b>${v}${total ? ` · ${pct}%` : ""}</b></div>
        <div class="bar__t"><div class="bar__f" style="width:${pct}%"></div></div></div>`;
    }).join("") + `</div>`;
  } else {
    results = `<div class="sealed">🔒 Esiti visibili solo dopo lo spoglio · opzioni: ${options.map(labelOf).join(" · ")}</div>`;
  }

  let actions = "";
  if (IS_GOV && isGovOfThis) {
    actions = `<div class="gov-ctl">
      <button class="btn btn--sm" data-act="phase" data-ref="${addr}" data-p="2" ${phase !== 1 ? "disabled" : ""}>Avvia spoglio</button>
      <button class="btn btn--sm btn--gov" data-act="close" data-ref="${addr}" ${phase !== 2 ? "disabled" : ""}>Chiudi e conta</button>
    </div>`;
  } else if (!IS_GOV) {
    if (phase === 1) {
      if (canVote) actions += voteForm(addr, options);
      else if (authorized) actions += `<p class="muted">La tua identità è per un'altra giurisdizione. Creane una per «${jur}».</p>${enrollForm(addr, jur)}`;
      else actions += enrollForm(addr, jur); // niente identità = niente voto
    }
    if (phase === 2 && me && me.committed) actions += revealForm(addr, options); // reveal solo in spoglio
  }

  const status = me && me.committed
    ? `<span class="pill ${me.revealed ? "pill--ok" : ""}">${me.revealed ? "✓ rivelato" : "✓ votato"}</span>` : "";

  return `<article class="ref-card">
    <div class="ref-card__top"><span class="phase phase--${phase}">${PHASES[phase]}</span>${status}</div>
    <h3>${title}</h3>
    <p class="ref-card__meta">📍 ${jur} · 🗳 ${committed} · ✅ ${revealed} · ${finalized ? "esito ufficiale" : "spoglio non concluso"}</p>
    ${results}
    ${identity}
    ${actions}
  </article>`;
}

function enrollForm(addr, jur) {
  return `<div class="act act--enroll">
    <span class="act__lbl">🔐 Per votare crea la tua identità SPID per questo referendum</span>
    <p class="muted">Firmi con SPID (simulato) l'autorizzazione a votare «${jur}». On-chain finisce solo la giurisdizione, nessun dato personale. Vale solo per questo referendum.</p>
    <button class="btn btn--spid btn--sm" data-enroll="${addr}" data-jur="${jur}">Crea identità SPID</button>
  </div>`;
}

function voteForm(addr, options) {
  const radios = options.map((o, i) =>
    `<label class="opt"><input type="radio" name="v-${addr}" value="${o}" ${i === 0 ? "checked" : ""}><span>${labelOf(o)}</span></label>`).join("");
  return `<form class="act" data-vote="${addr}">
    <div class="opts">${radios}</div>
    <div class="act__row">
      <input type="password" placeholder="nonce segreto" data-n="1" minlength="3" required>
      <input type="password" placeholder="ripeti nonce" data-n="2" minlength="3" required>
      <button class="btn btn--primary btn--sm">Vota</button>
    </div>
  </form>`;
}
function revealForm(addr, options) {
  const sel = options.map((o) => `<option value="${o}">${labelOf(o)}</option>`).join("");
  return `<form class="act" data-reveal="${addr}">
    <span class="act__lbl">Rivela il voto</span>
    <div class="act__row">
      <select data-opt>${sel}</select>
      <input type="password" placeholder="il tuo nonce" data-rn minlength="3" required>
      <button class="btn btn--sm">Rivela</button>
    </div>
  </form>`;
}

function wireCards() {
  document.querySelectorAll("[data-enroll]").forEach((b) => b.onclick = async () => {
    if (!S.router) return toast("Connetti il wallet (Sepolia) prima.", "err");
    const ok = await tx(
      S.router.simulatedSpidLogin(b.dataset.enroll, b.dataset.jur),
      "Identità SPID creata per questo referendum — on-chain solo la giurisdizione.",
    );
    if (ok) await refresh();
  });
  document.querySelectorAll("[data-vote]").forEach((f) => f.onsubmit = async (e) => {
    e.preventDefault();
    const addr = f.dataset.vote;
    const opt = f.querySelector(`input[name="v-${addr}"]:checked`).value;
    const n1 = f.querySelector('[data-n="1"]').value, n2 = f.querySelector('[data-n="2"]').value;
    if (n1 !== n2) return toast("I due nonce non coincidono.", "err");
    const c = new ethers.Contract(addr, REF_ABI, S.signer);
    const d = digestOf(opt, n1);
    const nt = nonceTagOf(n1);
    if (await c.usedNonce(nt)) return toast("Nonce già usato in questo referendum (con qualsiasi voto): scegline un altro.", "err");
    if (await tx(c.commit(d, nt), "Voto registrato sulla blockchain.")) await refresh();
  });
  document.querySelectorAll("[data-reveal]").forEach((f) => f.onsubmit = async (e) => {
    e.preventDefault();
    const addr = f.dataset.reveal;
    const opt = f.querySelector("[data-opt]").value, nonce = f.querySelector("[data-rn]").value;
    const c = new ethers.Contract(addr, REF_ABI, S.signer);
    if (await tx(c.reveal(ethers.encodeBytes32String(opt), nonce), "Reveal inviato.")) {
      const b = await c.ballots(S.account);
      const match = digestOf(opt, nonce) === b.lastDigest;
      toast(match ? "✅ Nonce corretto: scheda valida." : "⚠️ Nonce errato: pubblicato ma non conteggiabile.", match ? "ok" : "err");
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

function updateJurList() {
  const dl = $("jurList");
  if (dl) dl.innerHTML = [...seenJur].map((j) => `<option>${j}</option>`).join("");
}

// ============================================================ ESPLORA CHAIN (live)
// Ascolta gli eventi dei NOSTRI contratti su Sepolia e li traduce in linguaggio umano:
// cosa è successo, quali dati restano davvero on-chain, perché. Dà l'idea della blockchain.
const escapeHtml = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

const EXPLORER_IFACE = new ethers.Interface([
  "event GovernmentRegistered(address indexed government, string jurisdiction)",
  "event WalletAuthorized(address indexed referendum, address indexed wallet, string jurisdiction)",
  "event ReferendumCreated(address indexed referendum, address indexed government, string jurisdiction, string title)",
  "event Committed(address indexed voter, bytes32 digest, uint32 revision)",
  "event Revealed(address indexed voter, bytes32 vote, string nonce, bool matches)",
  "event PhaseChanged(uint8 phase)",
  "event Finalized(uint256 valid, uint256 nullified)",
  "event PollCreated(uint256 indexed id, address indexed creator, string question, uint128 stake)",
  "event Voted(uint256 indexed id, address indexed voter, bytes32 option, uint64 totalVotes)",
  "event PollWon(uint256 indexed id)",
  "event StakeClaimed(uint256 indexed id, address indexed creator, uint128 amount)",
]);
const PHASE_NAME = ["Configurazione", "Votazione", "Spoglio", "Chiuso"];
const shortA = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—");
const shortH = (h) => (h ? `${h.slice(0, 10)}…` : "—");

// nome evento -> come raccontarlo a un umano
const EVT_META = {
  ReferendumCreated: {
    ico: "📜", kind: "create", title: "Referendum emanato",
    sum: (a) => `«${a.title}» · ${a.jurisdiction}`,
    why: "Il governo ha pubblicato un nuovo contratto-referendum: da ora esiste in modo permanente e chiunque può verificarne regole ed esiti. Nessuno può cancellarlo.",
    data: (a) => [["Contratto", shortA(a.referendum)], ["Governo", shortA(a.government)], ["Giurisdizione", a.jurisdiction], ["Titolo", a.title]],
  },
  WalletAuthorized: {
    ico: "🪪", kind: "id", title: "Identità SPID creata",
    sum: (a) => `un cittadino si è autorizzato a votare (${a.jurisdiction})`,
    why: "Un cittadino ha firmato la sua identità SPID (simulata) per UN referendum. On-chain finisce solo la giurisdizione: niente nome, niente codice fiscale, nemmeno uno pseudonimo.",
    data: (a) => [["Per il referendum", shortA(a.referendum)], ["Wallet cittadino", shortA(a.wallet)], ["Giurisdizione", a.jurisdiction]],
  },
  GovernmentRegistered: {
    ico: "🏛", kind: "gov", title: "Governo registrato",
    sum: (a) => `autorità abilitata per ${a.jurisdiction}`,
    why: "Un indirizzo diventa autorità elettorale per una giurisdizione: solo lui potrà emanare referendum lì. È il controllo degli accessi scritto in chiaro nella catena.",
    data: (a) => [["Wallet governo", shortA(a.government)], ["Giurisdizione", a.jurisdiction]],
  },
  Committed: {
    ico: "🗳️", kind: "commit", title: "Voto segreto (commit)",
    sum: (a) => `impronta del voto depositata · revisione ${a.revision}`,
    why: "Il cuore del voto segreto: viene salvato solo keccak256(voto, nonce), un'impronta che NON rivela la scelta. Il voto è già registrato e immutabile, ma resta nascosto fino allo spoglio.",
    data: (a) => [["Elettore", shortA(a.voter)], ["Impronta (hash)", shortH(a.digest)], ["Revisione", String(a.revision)]],
  },
  Revealed: {
    ico: "🔓", kind: "reveal", title: "Voto rivelato (spoglio)",
    sum: (a) => `${decodeOpt(a.vote)} — ${a.matches ? "valido ✓" : "hash non combacia ✗"}`,
    why: "Durante lo spoglio l'elettore svela voto + nonce in chiaro. Chiunque può ricalcolare l'hash e verificare che combaci con quello depositato prima: il conteggio è verificabile da tutti.",
    data: (a) => [["Elettore", shortA(a.voter)], ["Voto in chiaro", decodeOpt(a.vote)], ["Nonce", a.nonce], ["Hash combacia?", a.matches ? "sì" : "no"]],
  },
  PhaseChanged: {
    ico: "⏱️", kind: "phase", title: "Cambio fase",
    sum: (a) => `→ ${PHASE_NAME[Number(a.phase)] ?? a.phase}`,
    why: "Il governo fa avanzare il ciclo di vita del referendum (Votazione → Spoglio → Chiuso). Ogni passaggio è una transazione tracciata: la sequenza non può essere falsificata.",
    data: (a) => [["Nuova fase", PHASE_NAME[Number(a.phase)] ?? String(a.phase)]],
  },
  Finalized: {
    ico: "✅", kind: "final", title: "Spoglio concluso",
    sum: (a) => `${a.valid} voti validi · ${a.nullified} nulli`,
    why: "Il referendum è chiuso: il conteggio ufficiale è stato calcolato dal contratto stesso e non è più modificabile. Gli esiti diventano pubblici e definitivi.",
    data: (a) => [["Voti validi", String(a.valid)], ["Voti nulli", String(a.nullified)]],
  },
  PollCreated: {
    ico: "💬", kind: "poll", title: "Sondaggio creato",
    sum: (a) => `«${a.question}» · cauzione ${ethers.formatEther(a.stake)}Ξ`,
    why: "Sondaggio social aperto a tutti: il creatore blocca una piccola cauzione (anti-spam) che riprende se il sondaggio raggiunge significatività statistica. I fondi sono custoditi dal contratto, non da una persona.",
    data: (a) => [["ID", String(a.id)], ["Creatore", shortA(a.creator)], ["Domanda", a.question], ["Cauzione", `${ethers.formatEther(a.stake)} ETH`]],
  },
  Voted: {
    ico: "✋", kind: "pollvote", title: "Voto sondaggio",
    sum: (a) => `${decodeOpt(a.option)} · totale ${a.totalVotes}`,
    why: "Voto pubblico (non segreto) in un sondaggio social. Ogni indirizzo può votare una sola volta: è il contratto a impedire i doppioni, senza bisogno di un'autorità centrale.",
    data: (a) => [["Sondaggio", String(a.id)], ["Votante", shortA(a.voter)], ["Opzione", decodeOpt(a.option)], ["Voti totali", String(a.totalVotes)]],
  },
  PollWon: {
    ico: "🏆", kind: "won", title: "Sondaggio vinto",
    sum: () => "risultato statisticamente significativo",
    why: "Il distacco fra le opzioni è abbastanza ampio da essere significativo (≈95%): il sondaggio è «vinto» e la cauzione diventa riscattabile.",
    data: (a) => [["Sondaggio", String(a.id)]],
  },
  StakeClaimed: {
    ico: "💸", kind: "claim", title: "Cauzione riscattata",
    sum: (a) => `${ethers.formatEther(a.amount)}Ξ restituiti al creatore`,
    why: "Il creatore riprende la cauzione dopo la vittoria del sondaggio: un trasferimento di ETH eseguito e tracciato dal contratto, verificabile da chiunque.",
    data: (a) => [["Sondaggio", String(a.id)], ["Creatore", shortA(a.creator)], ["Importo", `${ethers.formatEther(a.amount)} ETH`]],
  },
};

let EXPLORER_ON = false;
let chainWatch = []; // indirizzi dei nostri contratti da filtrare
const chainSeen = new Set(); // dedupe per txHash:logIndex
let chainItems = []; // eventi decodificati recenti (cap)

async function startExplorer() {
  if (!S.provider) return;
  chainWatch = [ADDR.router, ADDR.factory, ADDR.pollHub].filter((a) => ethers.isAddress(a));
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

function evtCard(it) {
  const m = EVT_META[it.name];
  const rows = m.data(it.args)
    .map(([k, v]) => `<div class="evt__kv"><span>${k}</span><b>${escapeHtml(String(v))}</b></div>`).join("");
  return `<article class="evt evt--${m.kind}" tabindex="0">
    <div class="evt__row"><span class="evt__ico">${m.ico}</span><span class="evt__title">${m.title}</span><span class="evt__blk">blocco #${it.block}</span></div>
    <div class="evt__sum">${escapeHtml(m.sum(it.args))}</div>
    <div class="evt__explain">
      <p class="evt__why">${m.why}</p>
      <div class="evt__data">${rows}</div>
      <a class="evt__link" href="https://sepolia.etherscan.io/tx/${it.hash}" target="_blank" rel="noopener">tx ${shortH(it.hash)} su Etherscan ↗</a>
    </div>
  </article>`;
}

function renderExplorer() {
  const box = $("chainFeed");
  if (!box) return;
  const head = $("chainHead");
  if (head) head.textContent = chainItems.length ? `in ascolto · ${chainItems.length} eventi recenti` : "in ascolto della rete…";
  if (!chainItems.length) {
    box.innerHTML = `<div class="evt-empty">Nessun evento ancora. Appena qualcuno crea un'identità, vota, o il governo emana/chiude un referendum, comparirà qui in tempo reale. 🔭</div>`;
    return;
  }
  box.innerHTML = chainItems.map(evtCard).join("");
  // tap-to-toggle per chi non ha l'hover (mobile)
  box.querySelectorAll(".evt").forEach((el) => {
    el.onclick = (e) => { if (e.target.closest(".evt__link")) return; el.classList.toggle("evt--open"); };
  });
}

// =================================================================== SOCIAL

function showView(which) {
  const social = which === "social";
  $("socialView").classList.toggle("hidden", !social);
  $("politicalView").classList.toggle("hidden", social);
  $("tabSocial").classList.toggle("is-active", social);
  $("tabPolitical").classList.toggle("is-active", !social);
  if (social) renderPolls();
}
$("tabPolitical").onclick = () => showView("political");
$("tabSocial").onclick = () => showView("social");

$("createPoll").onclick = async () => {
  if (!S.pollHub) return toast("Connetti il wallet su Sepolia (se manca, il gestore deve ridepoloyare con PollHub).", "err");
  const q = $("pollQ").value.trim();
  const opts = $("pollOpts").value.split("\n").map((s) => s.trim()).filter(Boolean);
  if (!q || opts.length < 2) return toast("Domanda + almeno 2 opzioni.", "err");
  if (opts.some((o) => o.length > 31)) return toast("Opzioni: max 31 caratteri.", "err");
  let value;
  try { value = ethers.parseEther(($("pollStake").value || "0").trim()); } catch { return toast("Cauzione non valida.", "err"); }
  if (value <= 0n) return toast("La cauzione deve essere maggiore di 0.", "err");
  const b32 = opts.map((o) => ethers.encodeBytes32String(o));
  const ok = await tx(S.pollHub.createPoll(q, b32, { value }), "Sondaggio pubblicato! 🎉");
  if (ok) { $("pollQ").value = ""; $("pollOpts").value = ""; await renderPolls(); }
};

async function renderPolls() {
  const feed = $("pollFeed");
  if (!S.pollHub) { feed.innerHTML = `<div class="empty">Sondaggi non disponibili su questa rete: il gestore deve ridepoloyare il sistema (con PollHub).</div>`; return; }
  let n;
  try { n = Number(await S.pollHub.pollsCount()); } catch (e) { feed.innerHTML = `<div class="empty">Errore: ${reason(e)}</div>`; return; }
  if (!n) { feed.innerHTML = `<div class="empty">Ancora nessun sondaggio. Creane uno qui sopra! ✨</div>`; return; }
  const ids = [...Array(n).keys()].reverse(); // più recenti in cima
  feed.innerHTML = (await Promise.all(ids.map(pollCard))).join("");
  wirePolls();
}

async function pollCard(id) {
  const p = await S.pollHub.getPoll(id);
  const creator = p.creator, question = p.question, optsRaw = p.options;
  const stake = p.stake, total = Number(p.totalVotes);
  const won = p.won, claimed = p.claimed;
  const options = optsRaw.map((b) => ethers.decodeBytes32String(b));
  const voted = await S.pollHub.hasVoted(id, S.account).catch(() => false);
  const isCreator = S.account && creator.toLowerCase() === S.account.toLowerCase();
  const counts = (await Promise.all(optsRaw.map((o) => S.pollHub.optionVotes(id, o)))).map(Number);

  const opts = options.map((o, i) => {
    const v = counts[i], pct = total ? Math.round((100 * v) / total) : 0;
    const dis = (voted || isCreator) ? "disabled" : "";
    return `<button class="poll-opt" data-pid="${id}" data-opt="${escapeHtml(o)}" ${dis}>
      <span class="poll-opt__l"><b>${escapeHtml(o)}</b><i>${v}${total ? ` · ${pct}%` : ""}</i></span>
      <span class="poll-opt__bar"><span style="width:${pct}%"></span></span></button>`;
  }).join("");

  // significatività: serve total>=5 e (primo-secondo) > 2·√total
  const sorted = [...counts].sort((a, b) => b - a);
  const lead = (sorted[0] || 0) - (sorted[1] || 0);
  const needLead = Math.floor(2 * Math.sqrt(total)) + 1;
  let prog, progLabel;
  if (won) { prog = 100; progLabel = "🏆 risultato statisticamente significativo"; }
  else if (total < 5) { prog = Math.round((100 * total) / 5); progLabel = `${total}/5 voti minimi`; }
  else { prog = Math.min(100, Math.round((100 * lead) / needLead)); progLabel = `vantaggio ${lead}/${needLead} per vincere (≈95%)`; }
  const badge = won ? `<span class="won">🏆 VINTO</span>` : `<span class="prog-pill">${total} voti</span>`;
  let claim = "";
  if (isCreator && won && !claimed) claim = `<button class="btn btn--social poll-claim" data-claim="${id}">💸 Reclama cauzione (${ethers.formatEther(stake)} ETH)</button>`;
  else if (isCreator && claimed) claim = `<span class="muted">✔ cauzione riscattata</span>`;
  const tags = `${isCreator ? '<span class="pill">tuo</span>' : ""}${voted ? '<span class="pill pill--ok">hai votato</span>' : ""}`;

  return `<article class="poll">
    <div class="poll__head">${avatar(creator)}<span class="addr">${creator.slice(0, 6)}…${creator.slice(-4)}</span>${tags}<span class="poll__stake">cauzione ${ethers.formatEther(stake)}Ξ</span>${badge}</div>
    <h3 class="poll__q">${escapeHtml(question)}</h3>
    <div class="poll__opts">${opts}</div>
    <div class="poll__prog"><div class="poll__progbar"><div style="width:${prog}%"></div></div><span>${progLabel}</span></div>
    ${claim}
  </article>`;
}

function wirePolls() {
  document.querySelectorAll(".poll-opt:not([disabled])").forEach((b) => b.onclick = async () => {
    const ok = await tx(S.pollHub.vote(Number(b.dataset.pid), ethers.encodeBytes32String(b.dataset.opt)), "Voto registrato! 🗳");
    if (ok) await renderPolls();
  });
  document.querySelectorAll("[data-claim]").forEach((b) => b.onclick = async () => {
    const ok = await tx(S.pollHub.claim(Number(b.dataset.claim)), "Cauzione riscattata 💸");
    if (ok) await renderPolls();
  });
}
