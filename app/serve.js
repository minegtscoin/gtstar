// Tiny static server for local preview of dist/.
const http = require("http"), fs = require("fs"), path = require("path");
const root = path.join(__dirname, "dist"), PORT = process.env.PORT || 4173;
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".svg": "image/svg+xml", ".css": "text/css" };
http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split("?")[0]); if (p === "/") p = "/index.html";
  const f = path.join(root, path.normalize(p).replace(/^(\.\.[/\\])+/, ""));
  fs.readFile(f, (e, d) => { if (e) { res.writeHead(404); return res.end("Not found"); }
    res.writeHead(200, { "Content-Type": TYPES[path.extname(f)] || "application/octet-stream" }); res.end(d); });
}).listen(PORT, () => console.log(`GTStar preview on http://localhost:${PORT}`));
