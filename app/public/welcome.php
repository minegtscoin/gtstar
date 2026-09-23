<?php
// Free first round for new players.
//   GET  /api/welcome?address=0x…   {open, amount, status: none|queued|sent|used, digest}
//   POST /api/welcome               {address, ts, signature}: ask for the welcome grant.
// Only brand-new wallets made with Google/Apple sign-in (zkLogin, e.g. Slush web) qualify: every such
// wallet needs its own Google/Apple account, which keeps farming expensive. The wallet signs
// "GTStar welcome\nAddress: <address>\nTime: <ts>"; Sui GraphQL checks the signature.
// Requests wait in ~/gtstar-data/welcome/queue/<address>; the keeper sends the SUI within seconds
// and moves the file to sent/<address> (contents: the transaction digest).
header("Content-Type: application/json; charset=utf-8");
header("Cache-Control: no-cache");

const AMOUNT_MIST = 20000000;   // 0.02 SUI: one 0.01 SUI tile plus gas for the first deploy
const DAILY_CAP = 25;           // grants per UTC day, at most 0.5 SUI a day

$dir = dirname(__DIR__, 3) . "/gtstar-data/welcome";
@mkdir("$dir/queue", 0700, true);
@mkdir("$dir/sent", 0700, true);
$fail = function ($code, $msg) { http_response_code($code); echo json_encode(["error" => $msg]); exit; };
$gql = function ($query, $vars) {
  $ctx = stream_context_create(["http" => ["method" => "POST", "header" => "Content-Type: application/json\r\n",
    "content" => json_encode(["query" => $query, "variables" => $vars]), "timeout" => 15, "ignore_errors" => true]]);
  $res = @file_get_contents("https://graphql.mainnet.sui.io/graphql", false, $ctx);
  return $res === false ? null : json_decode($res, true);
};
$today = function () use ($dir) {
  $n = 0; $start = strtotime("today UTC");
  foreach (array_merge(glob("$dir/sent/*") ?: [], glob("$dir/queue/*") ?: []) as $f) if (filemtime($f) >= $start) $n++;
  return $n;
};
$status = function ($addr) use ($dir) {
  if (is_file("$dir/sent/$addr")) return ["sent", trim(file_get_contents("$dir/sent/$addr"))];
  if (is_file("$dir/queue/$addr")) return ["queued", null];
  return ["none", null];
};

$addr = strtolower((string)($_GET["address"] ?? ""));
if ($_SERVER["REQUEST_METHOD"] === "GET") {
  $out = ["open" => $today() < DAILY_CAP, "amount" => AMOUNT_MIST];
  if (preg_match('/^0x[0-9a-f]{64}$/', $addr)) { [$s, $d] = $status($addr); $out["status"] = $s; $out["digest"] = $d; }
  echo json_encode($out); exit;
}
if ($_SERVER["REQUEST_METHOD"] !== "POST") $fail(405, "Method not allowed.");

$in = json_decode(file_get_contents("php://input"), true);
$addr = strtolower((string)($in["address"] ?? ""));
$ts = (int)($in["ts"] ?? 0);
$sig = (string)($in["signature"] ?? "");
if (!preg_match('/^0x[0-9a-f]{64}$/', $addr)) $fail(400, "Bad address.");
if (abs(time() - intdiv($ts, 1000)) > 600) $fail(400, "Signature expired. Try again.");
if ($sig === "" || !preg_match('#^[A-Za-z0-9+/=]+$#', $sig)) $fail(400, "Bad signature.");
[$s] = $status($addr);
if ($s !== "none") { echo json_encode(["status" => $s]); exit; }
// Signature scheme flag 0x05 = zkLogin (a wallet opened with Google, Apple and similar).
if (ord(base64_decode($sig)[0] ?? "\0") !== 0x05)
  $fail(403, "The free first round is for new wallets made with Google or Apple sign-in.");
if ($today() >= DAILY_CAP) $fail(429, "Today's free rounds are gone. Come back tomorrow.");

$msg = "GTStar welcome\nAddress: $addr\nTime: $ts";
$r = $gql('query($m:Base64!,$s:Base64!,$a:SuiAddress!){verifySignature(message:$m,signature:$s,intentScope:PERSONAL_MESSAGE,author:$a){success}}',
  ["m" => base64_encode($msg), "s" => $sig, "a" => $addr]);
if ($r === null) $fail(503, "Could not reach Sui. Try again.");
if (($r["data"]["verifySignature"]["success"] ?? false) !== true) $fail(401, "Signature check failed.");
// Brand-new wallets only: no transaction has ever touched this address.
$r = $gql('query($a:SuiAddress!){address(address:$a){transactions(first:1,relation:AFFECTED){nodes{digest}}}}', ["a" => $addr]);
if ($r === null || !isset($r["data"])) $fail(503, "Could not reach Sui. Try again.");
if (count($r["data"]["address"]["transactions"]["nodes"] ?? []) > 0)
  $fail(403, "The free first round is for brand-new wallets only.");

$f = @fopen("$dir/queue/$addr", "x");
if ($f) { fwrite($f, (string)time()); fclose($f); }
echo json_encode(["status" => "queued"]);
