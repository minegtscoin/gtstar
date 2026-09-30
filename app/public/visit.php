<?php
// Someone has the game open: the keeper's Pulse opens a round for them when none is live.
// Only the file's time is used (~/gtstar-data/visit); nothing about the visitor is stored.
$dir = dirname(__DIR__, 3) . "/gtstar-data";
if (!is_dir($dir)) mkdir($dir, 0700, true);
touch("$dir/visit");
http_response_code(204);
