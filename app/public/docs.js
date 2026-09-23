// Docs page: contract addresses and on-chain proofs from config.js.
(function(){
  var C = window.GTSTAR_CONFIG; if (!C) return;
  var scan = "https://suiscan.xyz/" + C.network;
  document.getElementById("netName").textContent = "Sui " + C.network.charAt(0).toUpperCase() + C.network.slice(1);
  var A = C.accounts || {};
  var rows = [
    ["GTS token", C.ids.token + "::gts::GTS", "coin", "The official GTS coin type. Check this address before you buy or trade GTS anywhere."],
    ["Token package", C.ids.token, "object", "The GTS token contract. Holds the emission ceiling and the reserve. Immutable: no one can change it."],
    ["Game package", C.ids.package, "object", "The game contract: rounds, deposits, the draw, fees and staking. It can only mint GTS through the token contract."],
    ["Treasury", C.ids.treasury, "object", "Controls all GTS minting within the fixed schedule and holds the SUI reserve that backs every GTS."],
    ["Board", C.ids.board, "object", "The shared game board. Holds the current round, its deposits and the minting right the game uses to pay out GTS."],
    ["Stake pool", C.ids.pool, "object", "Holds staked GTS and streams staking rewards to stakers."],
    ["GTS/SUI market", C.ids.market, "object", "The Cetus pool where GTS trades against SUI."],
    ["Upgrade authority", A.upgradeCap, "object", "The only key that can upgrade the game contract. It is locked inside the timelock below and can never be taken out."],
    ["Upgrade timelock", A.timelock, "object", "Holds the upgrade key. Every game upgrade must be announced here, with the exact fingerprint of the new code, 48 hours before it can run."],
    ["Timelock package", A.timelockPkg, "object", "The timelock contract. Immutable: the 48-hour delay can never be shortened."],
    ["Creator fee address", A.dev, "account", "Receives the fixed 1% creator fee. It holds no special rights over the game, the token or the reserve."],
    ["Keeper", A.keeper, "account", "Triggers the draw at the end of each round. It has no special rights: anyone can trigger a draw."]
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
