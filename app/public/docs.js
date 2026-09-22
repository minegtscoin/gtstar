// Docs page: contract addresses and on-chain proofs from config.js.
(function(){
  var C = window.GTSTAR_CONFIG; if (!C) return;
  var scan = "https://suiscan.xyz/" + C.network;
  document.getElementById("netName").textContent = "Sui " + C.network.charAt(0).toUpperCase() + C.network.slice(1);
  var rows = [["Token package", C.ids.token, "object"], ["Game package", C.ids.package, "object"], ["Board", C.ids.board, "object"], ["Treasury", C.ids.treasury, "object"], ["Stake pool", C.ids.pool, "object"], ["Creator", C.ids.dev, "account"]];
  var kv = document.getElementById("addrList");
  rows.forEach(function (r) {
    var k = document.createElement("span"); k.textContent = r[0];
    var a = document.createElement("a"); a.href = scan + "/" + r[2] + "/" + r[1]; a.target = "_blank"; a.rel = "noopener"; a.textContent = r[1];
    kv.append(k, a);
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
