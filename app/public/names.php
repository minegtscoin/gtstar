<?php
// Player usernames.
//   GET  /api/names   {address: name, ...} for every player who set one
//   POST /api/names   {address, name, ts, signature}: set (or clear, with name "") your username.
// The wallet signs "GTStar username: <name>\nAddress: <address>\nTime: <ts>" as a personal message;
// the signature is checked by Sui GraphQL (verifySignature covers every wallet scheme, zkLogin included).
// Stored outside public_html in ~/gtstar-data/names.json.
header("Content-Type: application/json; charset=utf-8");
header("Cache-Control: no-cache");

$dir = dirname(__DIR__, 3) . "/gtstar-data";
$file = "$dir/names.json";
$load = function () use ($file) { $j = is_file($file) ? json_decode(file_get_contents($file), true) : null; return is_array($j) ? $j : []; };
$fail = function ($code, $msg) { http_response_code($code); echo json_encode(["error" => $msg]); exit; };

if ($_SERVER["REQUEST_METHOD"] === "GET") { echo json_encode((object)$load()); exit; }
if ($_SERVER["REQUEST_METHOD"] !== "POST") $fail(405, "Method not allowed.");

$in = json_decode(file_get_contents("php://input"), true);
$addr = strtolower((string)($in["address"] ?? ""));
$name = trim((string)($in["name"] ?? ""));
$ts = (int)($in["ts"] ?? 0);
$sig = (string)($in["signature"] ?? "");
if (!preg_match('/^0x[0-9a-f]{64}$/', $addr)) $fail(400, "Bad address.");
if (abs(time() - intdiv($ts, 1000)) > 600) $fail(400, "Signature expired. Try again.");
if ($sig === "" || !preg_match('#^[A-Za-z0-9+/=]+$#', $sig)) $fail(400, "Bad signature.");
if ($name !== "") {
  if (!preg_match('/^[A-Za-z0-9](?:[A-Za-z0-9 ._-]{1,14})[A-Za-z0-9]$/', $name) || preg_match('/\s{2}/', $name))
    $fail(400, "3 to 16 characters: letters, numbers, space, dot, dash or underscore.");
  if (preg_match('/^0x/i', $name) || in_array(strtolower($name), ["you", "gtstar", "admin", "dev", "keeper", "reserve", "system"], true))
    $fail(400, "That name is reserved.");
}

$msg = "GTStar username: $name\nAddress: $addr\nTime: $ts";
$q = json_encode(["query" => "query(\$m:Base64!,\$s:Base64!,\$a:SuiAddress!){verifySignature(message:\$m,signature:\$s,intentScope:PERSONAL_MESSAGE,author:\$a){success}}",
  "variables" => ["m" => base64_encode($msg), "s" => $sig, "a" => $addr]]);
$ctx = stream_context_create(["http" => ["method" => "POST", "header" => "Content-Type: application/json\r\n", "content" => $q, "timeout" => 15, "ignore_errors" => true]]);
$res = @file_get_contents("https://graphql.mainnet.sui.io/graphql", false, $ctx);
if ($res === false) $fail(503, "Could not reach Sui to check the signature. Try again.");
if ((json_decode($res, true)["data"]["verifySignature"]["success"] ?? false) !== true) $fail(401, "Signature check failed.");

if (!is_dir($dir)) @mkdir($dir, 0700, true);
$fh = fopen($file, "c+");
if (!$fh || !flock($fh, LOCK_EX)) $fail(500, "Storage unavailable.");
$names = json_decode(stream_get_contents($fh), true) ?: [];
if ($name === "") unset($names[$addr]);
else {
  foreach ($names as $a => $n) if ($a !== $addr && strcasecmp($n, $name) === 0) { flock($fh, LOCK_UN); $fail(409, "That name is taken."); }
  $names[$addr] = $name;
}
ftruncate($fh, 0); rewind($fh); fwrite($fh, json_encode($names)); fflush($fh); flock($fh, LOCK_UN); fclose($fh);
echo json_encode(["ok" => true, "name" => $name]);
