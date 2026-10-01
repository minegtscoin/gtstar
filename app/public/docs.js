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
    ["Game", C.ids.latest || C.ids.package, "object", "The game code running now: rounds, the draw, fees, the buyback and emission."],
    ["Game board", C.ids.board, "object", "The live game state: rounds, the Wealth Fund, unrefined GTS and the locked liquidity positions."],
    ["GTS/SUI pool", C.ids.market, "object", "The Cetus pool GTS trades on, where the game buys back and adds liquidity."],
    ["Supply lock", C.ids.supplyLock, "object", "Immutable. Holds the right to mint GTS and never lets the total pass 1,000,000."],
    ["Daily mint limit", C.ids.mintLimit, "object", "Immutable. Lets at most 2,000 GTS be minted per UTC day."],
    ["Auto Mine vault", C.ids.autoVaultPkg, "object", "Immutable. Holds players' Auto Mine balances; only the player can withdraw."]
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
