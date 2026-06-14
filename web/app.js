/* VoteChain dApp — frontend statico (GitHub Pages + Sepolia). Solo wallet, niente backend.
   Indirizzi in config.js. Ruoli mutuamente esclusivi: l'account registrato come Governo
   on-chain vede SOLO il pannello Governo; tutti gli altri sono cittadini e votano. */

const PHASES = ["Configurazione", "Votazione aperta", "Spoglio in corso", "Referendum chiuso"];
const LABELS = { si: "Sì", no: "No", bianca: "Scheda Bianca" };
const seenJur = new Set(["Italia", "San Marino"]);
const CFG = (typeof CONFIG !== "undefined") ? CONFIG : { bootstrap: "", router: "", factory: "", chainId: 11155111 };

const ROUTER_ABI = [
  "function simulatedSpidLogin(bytes32 cfHash, string jurisdiction)",
  "function isAuthorized(address) view returns (bool)",
  "function jurisdictionOf(address) view returns (string)",
  "function canVote(address, string) view returns (bool)",
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
  "function usedDigest(bytes32) view returns (bool)",
  "function ballots(address) view returns (bytes32 lastDigest, bool committed, bool revealed, bytes32 lastVote, string lastNonce)",
  "function commit(bytes32)",
  "function reveal(bytes32, string)",
  "function setPhase(uint8)",
  "function close()",
];
const BOOTSTRAP_ABI = ["function addresses() view returns (address, address)"];

const S = { provider: null, signer: null, account: null, router: null, factory: null };
const ADDR = { router: "", factory: "" };
let GOV_JURS = [];
let IS_GOV = false;

const $ = (id) => document.getElementById(id);
const labelOf = (id) => LABELS[id] || id;
const digestOf = (voteId, nonce) =>
  ethers.solidityPackedKeccak256(["bytes32", "string"], [ethers.encodeBytes32String(voteId), nonce]);

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
}
$("connect").onclick = connect;
$("connectHero").onclick = connect;

async function resolveAddresses() {
  if (ethers.isAddress(CFG.router) && ethers.isAddress(CFG.factory)) {
    ADDR.router = CFG.router; ADDR.factory = CFG.factory; return true;
  }
  if (ethers.isAddress(CFG.bootstrap) && S.signer) {
    try {
      const [r, f] = await new ethers.Contract(CFG.bootstrap, BOOTSTRAP_ABI, S.signer).addresses();
      ADDR.router = r; ADDR.factory = f; return true;
    } catch { return false; }
  }
  return false;
}
function initContracts() {
  if (!ethers.isAddress(ADDR.router) || !ethers.isAddress(ADDR.factory)) return false;
  S.router = new ethers.Contract(ADDR.router, ROUTER_ABI, S.signer || S.provider);
  S.factory = new ethers.Contract(ADDR.factory, FACTORY_ABI, S.signer || S.provider);
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
  if (!IS_GOV) await refreshSpidStatus();
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

// -------------------------------------------------------------------- SPID
$("spidRandom").onclick = () => {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  let s = ""; for (let i = 0; i < 16; i++) s += chars[Math.floor(Math.random() * chars.length)];
  $("spidCf").value = s;
};
$("spidLogin").onclick = async () => {
  if (!S.router) return toast("Connetti il wallet (Sepolia) prima.", "err");
  const cf = $("spidCf").value.trim(), jur = $("spidJur").value.trim();
  if (!cf || !jur) return toast("Inserisci codice fiscale (qualsiasi) e giurisdizione.", "err");
  const cfHash = ethers.id(cf); // keccak256(utf8(cf)) — solo pseudonimo on-chain
  const ok = await tx(S.router.simulatedSpidLogin(cfHash, jur), "Identità SPID creata — on-chain solo lo pseudonimo.");
  if (ok) { $("spidCf").value = ""; $("spidNome").value = ""; $("spidCognome").value = ""; await refresh(); }
};
async function refreshSpidStatus() {
  try {
    const auth = await S.router.isAuthorized(S.account);
    const jur = auth ? await S.router.jurisdictionOf(S.account) : null;
    $("spidStatus").textContent = auth
      ? `✅ Identità attiva — giurisdizione: ${jur}. Puoi votare i referendum qui sotto.`
      : "Crea un'identità SPID simulata per poter votare.";
  } catch {}
}

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
  const cards = await Promise.all(addrs.map(card));
  box.innerHTML = cards.join("");
  wireCards();
  updateJurList();
}

async function card(addr) {
  const c = new ethers.Contract(addr, REF_ABI, S.signer || S.provider);
  const [title, jur, gov, phaseRaw, finalized, optsRaw, committed, revealed] = await Promise.all([
    c.title(), c.jurisdiction(), c.government(), c.phase(), c.finalized(), c.getOptions(),
    c.committedCount(), c.revealedCount(),
  ]);
  seenJur.add(jur);
  const phase = Number(phaseRaw);
  const options = optsRaw.map((b) => ethers.decodeBytes32String(b));
  const isGovOfThis = S.account && gov.toLowerCase() === S.account.toLowerCase();
  const me = await c.ballots(S.account).catch(() => null);
  const { counts, total } = await tallyCounts(c, optsRaw, options, finalized);

  const bars = options.map((o) => {
    const v = counts[o] || 0;
    const pct = total ? Math.round((100 * v) / total) : 0;
    return `<div class="bar"><div class="bar__l"><span>${labelOf(o)}</span><b>${v}${total ? ` · ${pct}%` : ""}</b></div>
      <div class="bar__t"><div class="bar__f" style="width:${pct}%"></div></div></div>`;
  }).join("");

  let actions = "";
  if (IS_GOV && isGovOfThis) {
    actions = `<div class="gov-ctl">
      <button class="btn btn--sm" data-act="phase" data-ref="${addr}" data-p="2" ${phase !== 1 ? "disabled" : ""}>Avvia spoglio</button>
      <button class="btn btn--sm btn--gov" data-act="close" data-ref="${addr}" ${phase !== 2 ? "disabled" : ""}>Chiudi e conta</button>
    </div>`;
  } else if (!IS_GOV) {
    const canVote = await S.router.canVote(S.account, jur).catch(() => false);
    if (phase === 1 && canVote) actions += voteForm(addr, options);
    if ((phase === 1 || phase === 2) && me && me.committed) actions += revealForm(addr, options, phase === 1);
    if (phase === 1 && !canVote) actions += `<p class="muted">Crea l'identità SPID per «${jur}» per votare.</p>`;
  }

  const status = me && me.committed
    ? `<span class="pill ${me.revealed ? "pill--ok" : ""}">${me.revealed ? "✓ rivelato" : "✓ votato"}</span>` : "";

  return `<article class="ref-card">
    <div class="ref-card__top"><span class="phase phase--${phase}">${PHASES[phase]}</span>${status}</div>
    <h3>${title}</h3>
    <p class="ref-card__meta">📍 ${jur} · 🗳 ${committed} · ✅ ${revealed} · ${finalized ? "esito ufficiale" : "provvisorio"}</p>
    <div class="bars">${bars}</div>
    ${actions}
  </article>`;
}

async function tallyCounts(c, optsRaw, options, finalized) {
  const counts = {}; let total = 0;
  options.forEach((o) => (counts[o] = 0));
  if (finalized) {
    for (let i = 0; i < optsRaw.length; i++) { counts[options[i]] = Number(await c.result(optsRaw[i])); }
    total = Object.values(counts).reduce((a, b) => a + b, 0);
    return { counts, total };
  }
  try {
    const voters = await c.getVoters();
    for (const v of voters) {
      const b = await c.ballots(v);
      if (!b.revealed) continue;
      const d = ethers.solidityPackedKeccak256(["bytes32", "string"], [b.lastVote, b.lastNonce]);
      if (d === b.lastDigest) {
        const id = ethers.decodeBytes32String(b.lastVote);
        if (id in counts) { counts[id]++; total++; }
      }
    }
  } catch {}
  return { counts, total };
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
function revealForm(addr, options, early) {
  const sel = options.map((o) => `<option value="${o}">${labelOf(o)}</option>`).join("");
  return `<form class="act" data-reveal="${addr}">
    <span class="act__lbl">${early ? "Conferma anticipata" : "Rivela il voto"}</span>
    <div class="act__row">
      <select data-opt>${sel}</select>
      <input type="password" placeholder="il tuo nonce" data-rn minlength="3" required>
      <button class="btn btn--sm">Rivela</button>
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
    if (await c.usedDigest(d)) return toast("Nonce già usato in questo referendum: scegline un altro.", "err");
    if (await tx(c.commit(d), "Voto registrato sulla blockchain.")) await refresh();
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
