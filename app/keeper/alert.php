<?php
// Low-balance email alert for the bot wallets. Run by the keeper cron (cron.mjs) every 10 minutes:
//   php ~/gtstar-keeper/alert.php          check and email if a wallet is low (at most once a day each)
//   php ~/gtstar-keeper/alert.php --test   send a test email with the current balances
const TO = "alerts@example.invalid";
const FROM = "GTStar Alerts <alerts@minegts.fun>";
const MIN_SUI = 1.5;
const MIN_SUI_BOT = 0.5; // the bots only need SUI for their own small rounds
const WALLETS = [
  "Keeper (draws rounds, pays the free first round)" => "0x22390096d8def0638c92f86da60683e37d1a7f00b4b22fcb359952db300c3549",
  "House (plays alongside real players)" => "0x4a6e7d021beb465ce1a68ffe45d6e18cd30f6aea45560364a8c59bcdd497458a",
  "Bot 1 (plays about 12 rounds a day)" => "0xab4deb30e34487f75bf5632038e46d419c6238b4ea52d35f3ad3421a5bb268fa",
  "Bot 2 (plays about 12 rounds a day)" => "0x779b49acf4db04d835440c12ffe24929de505a9b8112b4040da5103d225b37e7",
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
  if ($sui < (str_starts_with($name, "Bot") ? MIN_SUI_BOT : MIN_SUI) && time() - ($sent[$addr] ?? 0) > 86400) { $low[] = $name; $sent[$addr] = time(); }
}
if (!$low && !$test) exit(0);

$subject = $test ? "GTStar alerts are on" : "GTStar: top up " . implode(" and ", array_map(fn($n) => explode(" ", $n)[0], $low));
$body = ($test
    ? "Alerts are set up. You will get an email when a bot wallet drops below " . MIN_SUI . " SUI (at most once a day per wallet).\n\n"
    : "A bot wallet is below " . MIN_SUI . " SUI. Send SUI to the address below to keep the game running.\n\n")
  . implode("\n\n", $lines) . "\n\nhttps://minegts.fun\n";
$ok = mail(TO, $subject, $body, "From: " . FROM . "\r\nContent-Type: text/plain; charset=utf-8");
if ($ok && !$test) file_put_contents($state, json_encode($sent));
echo $ok ? "sent\n" : "mail failed\n";
