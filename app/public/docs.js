// Header menu (inline scripts are blocked by the site's CSP).
(function(){
  var b = document.getElementById("moreBtn"), m = document.getElementById("moreMenu");
  if (!b || !m) return;
  b.onclick = function (e) { e.stopPropagation(); m.hidden = !m.hidden; b.setAttribute("aria-expanded", !m.hidden); };
  document.addEventListener("click", function () { m.hidden = true; b.setAttribute("aria-expanded", "false"); });
})();
// Docs page: contract addresses and on-chain proofs from config.js.
(function(){
  var C = window.GTSTAR_CONFIG; if (!C) return;
  var scan = "https://suiscan.xyz/" + C.network;
  // Auto Mine text is shown only once it is live (its ids are in config.js then).
  if (C.ids.autoVault) {
    document.querySelectorAll("[data-auto]").forEach(function (e) { e.hidden = false; });
    document.querySelectorAll("[data-noauto]").forEach(function (e) { e.hidden = true; });
  }
  document.getElementById("netName").textContent = "Sui " + C.network.charAt(0).toUpperCase() + C.network.slice(1);
  var A = C.accounts || {};
  var rows = [
    ["GTS token", C.ids.token + "::gts::GTS", "coin", "The official coin type. Check it before you buy GTS anywhere."],
    ["Supply lock", C.ids.supplyLock, "object", "Immutable contract that holds the right to mint GTS. It never lets the total pass 1,000,000, and no one can change it."],
    ["Daily mint limit", C.ids.mintLimit, "object", "Immutable contract that holds the only key to the supply lock and lets at most 2,000 GTS through per UTC day. No one can change it."],
    ["Daily limiter", C.ids.mintLimiter, "object", "The limiter itself, kept in the game board: the 2,000 GTS a day limit and what was minted today."],
    ["Capped treasury", C.ids.treasury, "object", "The GTS mint authority, sealed in the supply lock: minted so far and the 1,000,000 limit. Holds no SUI."],
    ["Auto Mine vault contract", C.ids.autoVaultPkg, "object", "Immutable contract that holds players' Auto Mine balances. Only the player can withdraw, at any time, and no one can change it or pause it."],
    ["Auto Mine vault", C.ids.autoVault, "object", "The vault itself: every player's Auto Mine balance and plan."],
    ["Game contract", C.ids.package, "object", "Rounds, the draw, fees and emission."],
    ["Game board", C.ids.board, "object", "The live game state: rounds, the Wealth Fund and unrefined GTS."],
    ["GTS/SUI pool", C.ids.market, "object", "Cetus trading pool."]
  ].filter(function (r) { return r[1]; });
  var list0 = document.getElementById("addrList");
  rows.forEach(function (r) {
    var d = document.createElement("div");
    var k = document.createElement("b"); k.textContent = r[0];
    var a = document.createElement("a"); a.href = scan + "/" + r[2] + "/" + r[1]; a.target = "_blank"; a.rel = "noopener"; a.textContent = r[1];
    var t = document.createElement("p"); t.textContent = r[3];
    d.append(k, a, t); list0.appendChild(d);
  });
  var list = document.getElementById("proofList");
  var proof = C.proof || [];
  if (!proof.length) { list.outerHTML = '<p style="color:var(--dim)">Proofs will be listed after the first rounds.</p>'; return; }
  proof.forEach(function (p) {
    var a = document.createElement("a"); a.href = scan + "/tx/" + p[1]; a.target = "_blank"; a.rel = "noopener";
    var t = document.createElement("span"); t.textContent = p[0];
    var c = document.createElement("code"); c.textContent = p[1].slice(0, 8) + "…" + p[1].slice(-6);
    a.append(t, c); list.appendChild(a);
  });
})();
