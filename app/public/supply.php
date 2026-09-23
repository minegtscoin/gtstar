<?php
// Plain-number GTS supply for listing sites (CoinMarketCap, CoinGecko).
//   /api/supply/total        total GTS in existence (minted minus burned)
//   /api/supply/circulating  same as total: no premine, no team or locked tokens
//   /api/supply/max          most GTS that can ever exist: the emission ceiling at 2030-01-01
//                            for this genesis (below the 1,000,000 hard cap, which is never reached)
// Read live from the Treasury object on Sui, cached for 60 seconds.
header("Content-Type: text/plain; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: public, max-age=60");

$q = $_GET["q"] ?? "total";
if ($q === "max") { echo "572003.236678098"; exit; }
if ($q !== "total" && $q !== "circulating") { http_response_code(404); echo "unknown"; exit; }

$treasury = "0x1dfef30cd82739d4b70f71fdbe15dd9ad218324054401a3751ac7b91dcd1b786";
$cache = sys_get_temp_dir() . "/gtstar_supply.txt";
if (is_file($cache) && time() - filemtime($cache) < 60) { echo file_get_contents($cache); exit; }

$body = json_encode(["query" => "{object(address:\"$treasury\"){asMoveObject{contents{json}}}}"]);
$ctx = stream_context_create(["http" => ["method" => "POST", "header" => "Content-Type: application/json\r\n", "content" => $body, "timeout" => 10]]);
$res = @file_get_contents("https://graphql.mainnet.sui.io/graphql", false, $ctx);
$raw = $res ? (json_decode($res, true)["data"]["object"]["asMoveObject"]["contents"]["json"]["cap"]["total_supply"]["value"] ?? null) : null;
if ($raw === null || !ctype_digit((string)$raw)) {
  if (is_file($cache)) { echo file_get_contents($cache); exit; }
  http_response_code(503); echo "unavailable"; exit;
}
$raw = str_pad((string)$raw, 10, "0", STR_PAD_LEFT);
$out = rtrim(rtrim(substr($raw, 0, -9) . "." . substr($raw, -9), "0"), ".");
@file_put_contents($cache, $out);
echo $out;
