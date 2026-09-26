<?php
// Game event history, cached so the site does not page through every event on each visit.
//   GET /api/history   {at, settled:[…], deployed:[…], redeemed:[…], staked:[…], unstaked:[…], ml:[…]}
// Each list is oldest first, entries {ts, sender, digest, j} exactly as Sui GraphQL returns them.
// The cache only ever appends: each type keeps its GraphQL cursor and fetches the events after it.
// Stored outside public_html in ~/gtstar-data/history.json; refreshed at most every 5 seconds.
header("Content-Type: application/json; charset=utf-8");
header("Cache-Control: no-cache");

$GAME = "0x2cef85db37c28fccda8b409e2a321ee5932e1b292b596877184245972250004e";
$TOKEN = "0x39019f183d8d19df19bd7c3e14fed735c7a1b11e2aa02669eba1089602394c3e";
$ML = "0x18c62dc69524cfe585d2a27a08e48484e370bcfc1b57c5f882b477d85e5058a6";
$TYPES = [
  "settled" => "$GAME::game::RoundSettled", "deployed" => "$GAME::game::Deployed", "redeemed" => "$TOKEN::gts::Redeemed",
  "staked" => "$GAME::staking::Staked", "unstaked" => "$GAME::staking::Unstaked", "ml" => "$ML::game::MotherlodeUpdate",
];

$dir = dirname(__DIR__, 3) . "/gtstar-data";
$file = "$dir/history.json";
$serve = function () use ($file) {
  if (!is_file($file)) { http_response_code(503); echo json_encode(["error" => "unavailable"]); exit; }
  $h = json_decode(file_get_contents($file), true);
  $out = ["at" => $h["at"] ?? 0];
  foreach ($h["types"] ?? [] as $k => $t) $out[$k] = $t["list"];
  echo json_encode($out, JSON_UNESCAPED_SLASHES);
  exit;
};
if (is_file($file) && time() - filemtime($file) < 5) $serve();

// One updater at a time; everyone else gets the current file.
@mkdir($dir, 0700, true);
$lock = fopen("$dir/history.lock", "c");
if (!$lock || !flock($lock, LOCK_EX | LOCK_NB)) $serve();

$h = is_file($file) ? json_decode(file_get_contents($file), true) : null;
if (!is_array($h)) $h = ["types" => []];
// The next page of every type that has one, all requested at once.
$ok = true;
$todo = array_keys($TYPES);
foreach ($todo as $k) $h["types"][$k] ??= ["cursor" => null, "list" => []];
for ($round = 0; $todo && $round < 40; $round++) {
  $mh = curl_multi_init(); $hs = [];
  foreach ($todo as $k) {
    $c = $h["types"][$k]["cursor"];
    $after = $c ? ",after:\"$c\"" : "";
    $q = "{events(filter:{type:\"{$TYPES[$k]}\"},first:50$after){pageInfo{hasNextPage endCursor} nodes{timestamp sender{address} transaction{digest} contents{json}}}}";
    $ch = curl_init("https://graphql.mainnet.sui.io/graphql");
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode(["query" => $q]), CURLOPT_HTTPHEADER => ["Content-Type: application/json"], CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 8, CURLOPT_ENCODING => ""]);
    curl_multi_add_handle($mh, $ch); $hs[$k] = $ch;
  }
  do { $st = curl_multi_exec($mh, $running); if ($running) curl_multi_select($mh, 1); } while ($running && $st === CURLM_OK);
  $next = [];
  foreach ($hs as $k => $ch) {
    $j = json_decode((string)curl_multi_getcontent($ch), true);
    curl_multi_remove_handle($mh, $ch);
    $e = empty($j["errors"]) ? ($j["data"]["events"] ?? null) : null;
    if (!$e) { $ok = false; continue; }
    foreach ($e["nodes"] as $n) $h["types"][$k]["list"][] = ["ts" => $n["timestamp"], "sender" => $n["sender"]["address"] ?? null, "digest" => $n["transaction"]["digest"] ?? null, "j" => $n["contents"]["json"] ?? (object)[]];
    if ($e["pageInfo"]["endCursor"]) $h["types"][$k]["cursor"] = $e["pageInfo"]["endCursor"];
    if ($e["pageInfo"]["hasNextPage"]) $next[] = $k;
  }
  curl_multi_close($mh);
  $todo = $next;
}
if ($todo) $ok = false;
// A failed read keeps the events already fetched (the cursor only moves past stored events) but is retried on the next request.
if ($ok) $h["at"] = time();
$tmp = "$file.tmp";
if (file_put_contents($tmp, json_encode($h, JSON_UNESCAPED_SLASHES)) !== false) rename($tmp, $file);
if (!$ok) @touch($file, time() - 5);
flock($lock, LOCK_UN);
$serve();
