// Docs page: contract addresses and on-chain proofs from config.js.
(function(){
  var C = window.GTSTAR_CONFIG; if (!C) return;
  var scan = "https://suiscan.xyz/" + C.network;
  document.getElementById("netName").textContent = "Sui " + C.network.charAt(0).toUpperCase() + C.network.slice(1);
  var A = C.accounts || {};
  var rows = [
    ["GTS token", C.ids.token + "::gts::GTS", "coin", "The official coin type. Check it before you buy GTS anywhere."],
    ["Reserve", C.ids.treasury, "object", "The SUI that backs every GTS."],
    ["Game contract", C.ids.package, "object", "Rounds, the draw, fees and staking."],
    ["Upgrade timelock", A.timelock, "object", "Every game upgrade is announced here 48 hours in advance."],
    ["GTS/SUI pool", C.ids.market, "object", "Cetus trading pool. Its liquidity is burned."],
    ["Creator fee", A.dev, "account", "Receives the 1% creator fee. No special rights."]
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
