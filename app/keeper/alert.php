<?php
// Low-balance email alert for the keeper wallet (the only one the game needs to run). Run by the keeper cron (cron.mjs) every 10 minutes:
//   php ~/gtstar-keeper/alert.php          check and email if a wallet is low (at most once a day each)
//   php ~/gtstar-keeper/alert.php --test   send a test email with the current balances
// Recipient comes from ALERT_TO in the keeper's .env (kept off GitHub).
$env = is_file(__DIR__ . "/.env") ? file_get_contents(__DIR__ . "/.env") : "";
define("TO", preg_match('/^\s*ALERT_TO\s*=\s*(\S+)\s*$/m', $env, $m) ? $m[1] : "");
if (TO === "") exit(1);
const FROM = "GTStar Alerts <alerts@minegts.fun>";
const MIN_SUI = 1.5;
const WALLETS = [
  "Keeper (draws rounds, pays the free first round)" => "0x22390096d8def0638c92f86da60683e37d1a7f00b4b22fcb359952db300c3549",
];
$state = __DIR__ . "/.alert-state.json";
$test = in_array("--test", $argv ?? [], true);

$q = "{" . implode(" ", array_map(fn($i, $a) => "w$i:address(address:\"$a\"){balance(coinType:\"0x2::sui::SUI\"){totalBalance}}",
  array_keys(array_values(WALLETS)), array_values(WALLETS))) . "}";
$ctx = stream_context_create(["http" => ["method" => "POST", "header" => "Content-Type: application/json\r\n",
  "content" => json_encode(["query" => $q]), "timeout" => 20, "ignore_errors" => true]]);
$res = json_decode((string)@file_get_contents("https://graphql.mainnet.sui.io/graphql", false, $ctx), true);
if (!isset($res["data"])) exit(1);

$sent = is_file($state) ? (json_decode(file_get_contents($state), true) ?: []) : [];
$i = 0;
$lines = [];
$low = [];
foreach (WALLETS as $name => $addr) {
  $sui = ((int)($res["data"]["w$i"]["balance"]["totalBalance"] ?? 0)) / 1e9;
  $i++;
  $lines[] = sprintf("%s: %.3f SUI\n%s", $name, $sui, $addr);
  if ($sui < MIN_SUI && time() - ($sent[$addr] ?? 0) > 86400) { $low[] = $name; $sent[$addr] = time(); }
}
if (!$low && !$test) exit(0);

$subject = $test ? "GTStar alerts are on" : "GTStar: top up the keeper";
$body = ($test
    ? "Alerts are set up. You will get an email when the keeper drops below " . MIN_SUI . " SUI (at most once a day).\n\n"
    : "The keeper is below " . MIN_SUI . " SUI. Send SUI to the address below to keep rounds drawing.\n\n")
  . implode("\n\n", $lines) . "\n\nhttps://minegts.fun\n";
$ok = mail(TO, $subject, $body, "From: " . FROM . "\r\nContent-Type: text/plain; charset=utf-8");
if ($ok && !$test) file_put_contents($state, json_encode($sent));
echo $ok ? "sent\n" : "mail failed\n";
