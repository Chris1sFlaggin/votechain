/* VoteChain dApp — static frontend. Talks straight to the Solidity contracts via
   ethers.js + a browser wallet (MetaMask). No application backend. */

const PHASES = ["Configurazione", "Votazione aperta", "Spoglio in corso", "Referendum chiuso"];
const seenJur = new Set(["Italia", "San Marino"]); // jurisdictions offered in the datalist
const LABELS = { si: "Sì", no: "No", bianca: "Scheda Bianca" };

const ROUTER_ABI = [
  "function simulatedSpidLogin(bytes32 cfHash)",
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

const BOOTSTRAP_ABI = [
  "function addresses() view returns (address, address)",
  "function router() view returns (address)",
  "function factory() view returns (address)",
];

const LS = "votechain.cfg";
const loadCfg = () => { try { return JSON.parse(localStorage.getItem(LS)) || {}; } catch { return {}; } };
const persistCfg = (c) => localStorage.setItem(LS, JSON.stringify(c));

const S = { provider: null, signer: null, account: null, router: null, factory: null };
const $ = (id) => document.getElementById(id);
const labelOf = (id) => LABELS[id] || id;
const digestOf = (voteId, nonce) =>
  ethers.solidityPackedKeccak256(["bytes32", "string"], [ethers.encodeBytes32String(voteId), nonce]);

function toast(msg, kind = "ok") {
  const t = $("toast");
  t.textContent = msg; t.className = `toast toast--${kind}`;
  setTimeout(() => t.classList.add("hidden"), 4500);
}
async function tx(promise, ok) {
  try { toast("Transazione inviata…", "wait"); const r = await promise; await r.wait(); toast(ok, "ok"); return true; }
  catch (e) { toast(reason(e), "err"); return false; }
}
function reason(e) {
  const s = e?.shortMessage || e?.reason || e?.message || String(e);
  const m = s.match(/(NonceGiaUtilizzato|OutOfJurisdiction|WalletNotAuthorized|NotGovernment|VotingNotOpen|RevealClosed|NoVote|CloseOnlyFromTally|AlreadyFinalized|UnknownIdentity|EmptyOptions)/);
  return m ? `Errore contratto: ${m[1]}` : s;
}

// ------------------------------------------------------------------ wallet
$("connect").onclick = async () => {
  if (!window.ethereum) return toast("MetaMask non rilevato.", "err");
  S.provider = new ethers.BrowserProvider(window.ethereum);
  await S.provider.send("eth_requestAccounts", []);
  S.signer = await S.provider.getSigner();
  S.account = await S.signer.getAddress();
  const net = await S.provider.getNetwork();
  const netName = net.name && net.name !== "unknown" ? net.name : `chain ${net.chainId}`;
  $("who").textContent = `👤 ${S.account.slice(0, 6)}…${S.account.slice(-4)} · ${netName}`;
  $("who").classList.remove("hidden");
  $("connect").textContent = "Connesso";
  window.ethereum.on?.("accountsChanged", () => location.reload());
  window.ethereum.on?.("chainChanged", () => location.reload());
  if (!initContracts()) toast("Imposta gli indirizzi dei contratti (⚙️ Configurazione).", "err");
  await refresh();
};

function initContracts() {
  const r = $("routerAddr").value.trim(), f = $("factoryAddr").value.trim();
  if (!ethers.isAddress(r) || !ethers.isAddress(f)) { S.router = null; S.factory = null; return false; }
  S.router = new ethers.Contract(r, ROUTER_ABI, S.signer || S.provider);
  S.factory = new ethers.Contract(f, FACTORY_ABI, S.signer || S.provider);
  persistCfg({ boot: $("bootAddr").value.trim(), router: r, factory: f });
  return true;
}

$("saveCfg").onclick = async () => {
  if (initContracts()) { await refresh(); toast("Configurazione salvata.", "ok"); }
  else toast("Indirizzi Router/Factory non validi.", "err");
};

$("loadBoot").onclick = async () => {
  const b = $("bootAddr").value.trim();
  if (!ethers.isAddress(b)) return toast("Indirizzo Bootstrap non valido.", "err");
  const ro = S.provider || (window.ethereum ? new ethers.BrowserProvider(window.ethereum) : null);
  if (!ro) return toast("Connetti il wallet prima.", "err");
  try {
    const [r, f] = await new ethers.Contract(b, BOOTSTRAP_ABI, ro).addresses();
    $("routerAddr").value = r; $("factoryAddr").value = f;
    if (initContracts()) { await refresh(); toast("Router/Factory caricati dal Bootstrap.", "ok"); }
  } catch (e) { toast("Lettura Bootstrap fallita: " + reason(e), "err"); }
};

$("deployBtn").onclick = async () => {
  if (!S.signer) return toast("Connetti il wallet prima.", "err");
  if (typeof SYSTEM_BOOTSTRAP === "undefined") return toast("Bytecode non caricato (contracts.js).", "err");
  try {
    const net = await S.provider.getNetwork();
    const nn = net.name && net.name !== "unknown" ? net.name : "chain " + net.chainId;
    toast(`Deploy su ${nn}… conferma in MetaMask e attendi`, "wait");
    const factory = new ethers.ContractFactory(SYSTEM_BOOTSTRAP.abi, SYSTEM_BOOTSTRAP.bytecode, S.signer);
    const c = await factory.deploy();
    await c.waitForDeployment();
    $("bootAddr").value = await c.getAddress();
    const [r, f] = await c.addresses();
    $("routerAddr").value = r;
    $("factoryAddr").value = f;
    if (initContracts()) { await refresh(); toast("Sistema deployato! Ora crea l'identità SPID e vota.", "ok"); }
  } catch (e) { toast("Deploy fallito: " + reason(e), "err"); }
};

$("adminToggle").onclick = () => $("adminArea").classList.toggle("hidden");

$("addNet").onclick = async () => {
  if (!window.ethereum) return toast("MetaMask non rilevato.", "err");
  try {
    await window.ethereum.request({ method: "wallet_addEthereumChain", params: [{
      chainId: "0x7a69", chainName: "Anvil (local)", rpcUrls: ["http://127.0.0.1:8545"],
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    }] });
    toast("Rete Anvil aggiunta a MetaMask.", "ok");
  } catch (e) { toast(reason(e), "err"); }
};

// -------------------------------------------------------------------- SPID
$("spidRandom").onclick = () => {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  let s = ""; for (let i = 0; i < 16; i++) s += chars[Math.floor(Math.random() * chars.length)];
  $("spidCf").value = s;
};
$("spidLogin").onclick = async () => {
  if (!S.router) return toast("Connetti il wallet e configura i contratti prima.", "err");
  const cf = $("spidCf").value.trim();
  const jur = $("spidJur").value.trim();
  if (!cf || !jur) return toast("Inserisci codice fiscale (qualsiasi) e giurisdizione.", "err");
  // PoC privacy: name/surname are NEVER sent on-chain nor stored — only the pseudonym.
  const cfHash = ethers.id(cf); // keccak256(utf8(cf))
  const ok = await tx(S.router.simulatedSpidLogin(cfHash, jur),
    "Identità SPID simulata creata — on-chain solo lo pseudonimo, niente nome/cognome.");
  if (ok) { $("spidCf").value = ""; $("spidNome").value = ""; $("spidCognome").value = ""; await refresh(); }
};

async function refreshSpidStatus() {
  if (!S.router || !S.account) return;
  try {
    const auth = await S.router.isAuthorized(S.account);
    const jur = auth ? await S.router.jurisdictionOf(S.account) : null;
    $("spidStatus").textContent = auth
      ? `✅ Wallet autorizzato — giurisdizione: ${jur}`
      : "⚠️ Wallet non ancora autorizzato (fai il login SPID simulato).";
  } catch { $("spidStatus").textContent = ""; }
}

// ---------------------------------------------------------------- governo
async function refreshGovPanel() {
  if (!S.router || !S.account) return;
  const jurs = [];
  for (const j of ["Italia", "San Marino"]) {
    try { if (await S.router.isGovernment(S.account, j)) jurs.push(j); } catch {}
  }
  if (jurs.length) {
    $("govCard").classList.remove("hidden");
    $("govJurs").textContent = jurs.join(", ");
    $("newJur").innerHTML = jurs.map((j) => `<option>${j}</option>`).join("");
  } else $("govCard").classList.add("hidden");
}
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
async function refresh() {
  await refreshSpidStatus();
  await refreshGovPanel();
  await renderReferenda();
}

async function renderReferenda() {
  const box = $("referenda");
  if (!S.factory) { box.innerHTML = ""; return; }
  let addrs = [];
  try { addrs = await S.factory.getReferenda(); } catch (e) { box.innerHTML = `<p class="muted">Impossibile leggere i referendum: ${reason(e)}</p>`; return; }
  if (!addrs.length) { box.innerHTML = `<p class="muted">Nessun referendum on-chain.</p>`; return; }
  const cards = await Promise.all(addrs.map(card));
  box.innerHTML = cards.join("");
  wireCards();
  updateJurList();
}

function updateJurList() {
  const dl = $("jurList");
  if (dl) dl.innerHTML = [...seenJur].map((j) => `<option>${j}</option>`).join("");
}

async function card(addr) {
  const c = new ethers.Contract(addr, REF_ABI, S.signer);
  const [title, jur, gov, phaseRaw, finalized, optsRaw] = await Promise.all([
    c.title(), c.jurisdiction(), c.government(), c.phase(), c.finalized(), c.getOptions(),
  ]);
  seenJur.add(jur);
  const phase = Number(phaseRaw);
  const options = optsRaw.map((b) => ethers.decodeBytes32String(b));
  const isGov = S.account && gov.toLowerCase() === S.account.toLowerCase();
  const canVote = await S.router.canVote(S.account, jur).catch(() => false);
  const me = await c.ballots(S.account).catch(() => null);
  const counts = await tallyCounts(c, optsRaw, options, finalized);

  const bars = options.map((o) =>
    `<div class="bar"><div class="bar__l"><span>${labelOf(o)}</span><b>${counts[o] || 0}</b></div></div>`).join("");

  let actions = "";
  if (phase === 1 && canVote) actions += voteForm(addr, options);
  if ((phase === 1 || phase === 2) && me && me.committed) actions += revealForm(addr, options, phase === 1);
  if (phase === 1 && !canVote && S.account)
    actions += `<p class="muted">Non puoi votare qui (fuori giurisdizione o login SPID mancante).</p>`;

  let govCtl = "";
  if (isGov) {
    govCtl = `<div class="gov-ctl">
      <button class="btn btn--sm" data-act="phase" data-ref="${addr}" data-p="1" ${phase === 1 || finalized ? "disabled" : ""}>Apri voto</button>
      <button class="btn btn--sm" data-act="phase" data-ref="${addr}" data-p="2" ${phase !== 1 ? "disabled" : ""}>Spoglio</button>
      <button class="btn btn--sm btn--gov" data-act="close" data-ref="${addr}" ${phase !== 2 ? "disabled" : ""}>Chiudi e conta</button>
    </div>`;
  }

  const status = me && me.committed
    ? `<span class="pill pill--ok">${me.revealed ? "✓ rivelato" : "✓ votato"}</span>` : "";

  return `<div class="ref-card">
    <div class="ref-card__top"><span class="phase phase--${phase}">${PHASES[phase]}</span>${status}</div>
    <h3>${title}</h3>
    <p class="muted">${jur} · ${finalized ? "esito ufficiale" : "conteggio provvisorio"}</p>
    <div class="bars">${bars}</div>
    ${govCtl}
    ${actions}
  </div>`;
}

async function tallyCounts(c, optsRaw, options, finalized) {
  const out = {};
  if (finalized) {
    for (let i = 0; i < optsRaw.length; i++) out[options[i]] = Number(await c.result(optsRaw[i]));
    return out;
  }
  // provisional: replicate close() off-chain over the voters
  options.forEach((o) => (out[o] = 0));
  try {
    const voters = await c.getVoters();
    for (const v of voters) {
      const b = await c.ballots(v);
      if (!b.revealed) continue;
      const d = ethers.solidityPackedKeccak256(["bytes32", "string"], [b.lastVote, b.lastNonce]);
      if (d === b.lastDigest) {
        const id = ethers.decodeBytes32String(b.lastVote);
        if (id in out) out[id]++;
      }
    }
  } catch {}
  return out;
}

function voteForm(addr, options) {
  const radios = options.map((o, i) =>
    `<label class="opt"><input type="radio" name="v-${addr}" value="${o}" ${i === 0 ? "checked" : ""}> ${labelOf(o)}</label>`).join("");
  return `<form class="act" data-vote="${addr}">
    <div class="opts">${radios}</div>
    <input type="password" placeholder="nonce segreto" data-n="1" minlength="3" required>
    <input type="password" placeholder="ripeti nonce" data-n="2" minlength="3" required>
    <button class="btn btn--primary btn--sm">Vota (commit)</button>
  </form>`;
}
function revealForm(addr, options, early) {
  const sel = options.map((o) => `<option value="${o}">${labelOf(o)}</option>`).join("");
  return `<form class="act" data-reveal="${addr}">
    <span class="muted">${early ? "Conferma anticipata" : "Reveal"}:</span>
    <select data-opt>${sel}</select>
    <input type="password" placeholder="il tuo nonce" data-rn minlength="3" required>
    <button class="btn btn--sm">Rivela</button>
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
    if (await tx(c.commit(d), `Voto registrato (digest ${d.slice(0, 10)}…).`)) await refresh();
  });
  document.querySelectorAll("[data-reveal]").forEach((f) => f.onsubmit = async (e) => {
    e.preventDefault();
    const addr = f.dataset.reveal;
    const opt = f.querySelector("[data-opt]").value;
    const nonce = f.querySelector("[data-rn]").value;
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
    if (await tx(c.setPhase(Number(b.dataset.p)), "Fase aggiornata.")) await refresh();
  });
  document.querySelectorAll('[data-act="close"]').forEach((b) => b.onclick = async () => {
    const c = new ethers.Contract(b.dataset.ref, REF_ABI, S.signer);
    if (await tx(c.close(), "Referendum chiuso: conteggio ufficiale on-chain.")) await refresh();
  });
}

(function initUI() {
  const c = loadCfg();
  if (c.boot) $("bootAddr").value = c.boot;
  if (c.router) $("routerAddr").value = c.router;
  if (c.factory) $("factoryAddr").value = c.factory;
})();
