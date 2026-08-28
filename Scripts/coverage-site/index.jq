def metric_sum($items; $name):
    reduce $items[] as $item (
        {covered: 0, count: 0};
        .covered += ($item.summary[$name].covered // 0)
        | .count += ($item.summary[$name].count // 0)
    );

def percentage_number($metric):
    if $metric.count == 0 then 0
    else (($metric.covered * 10000 / $metric.count) | floor) / 100
    end;

def percentage($metric):
    (percentage_number($metric) | tostring) + "%";

def tone($metric):
    if percentage_number($metric) == 100 then "excellent"
    elif percentage_number($metric) >= 70 then "good"
    else "needs-work"
    end;

def html_escape:
    gsub("&"; "&amp;")
    | gsub("<"; "&lt;")
    | gsub(">"; "&gt;")
    | gsub("\""; "&quot;");

def metric_card($label; $metric; $description):
    "<article class=\"metric-card \(tone($metric))\">"
    + "<span class=\"metric-label\">\($label)</span>"
    + "<strong>\(percentage($metric))</strong>"
    + "<span class=\"metric-count\">\($metric.covered) of \($metric.count)</span>"
    + "<div class=\"progress\"><span style=\"width: \(percentage($metric))\"></span></div>"
    + "<p>\($description)</p>"
    + "</article>";

def github_mark:
    "<svg class=\"github-mark\" viewBox=\"0 0 24 24\" aria-hidden=\"true\" focusable=\"false\"><path d=\"M12 .297C5.37.297 0 5.67 0 12.297c0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.084-.729.084-.729 1.205.084 1.838 1.237 1.838 1.237 1.07 1.835 2.809 1.305 3.495.998.108-.776.418-1.305.762-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297 24 5.67 18.627.297 12 .297Z\"/></svg>";

[
    .data[0].files[]
    | select(.filename | startswith($root))
    | . + {relative: (.filename | ltrimstr($root))}
    | select(.relative | startswith(".build/") | not)
    | select(.relative | startswith("Tests/") | not)
] as $files
| (metric_sum($files; "lines")) as $lines
| (metric_sum($files; "functions")) as $functions
| (metric_sum($files; "regions")) as $regions
| ($files | sort_by(.relative | split("/")[0]) | group_by(.relative | split("/")[0])) as $areas
| [
    "<!doctype html>",
    "<html lang=\"en\">",
    "<head>",
    "<meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "<meta name=\"theme-color\" content=\"#0b0b10\">",
    "<meta name=\"description\" content=\"Signstr is a Nostr signer for iPhone and Mac. Explore the project and its live test coverage.\">",
    "<title>Signstr · Your keys. Your consent.</title>",
    "<link rel=\"icon\" type=\"image/png\" sizes=\"180x180\" href=\"signstr-icon.png\">",
    "<link rel=\"apple-touch-icon\" sizes=\"180x180\" href=\"signstr-icon.png\">",
    "<link rel=\"stylesheet\" href=\"coverage.css\">",
    "</head>",
    "<body>",
    "<div class=\"page-glow glow-one\"></div><div class=\"page-glow glow-two\"></div>",
    "<header class=\"site-header\">",
    "<a class=\"brand\" href=\"./\" aria-label=\"Signstr home\"><img src=\"signstr-icon.png\" alt=\"\"><span><strong>Signstr</strong><small>Nostr signer</small></span></a>",
    ("<nav><a href=\"#how-it-works\">How it works</a><a href=\"#nip46-test\">Test NIP-46</a><a href=\"#coverage\">Coverage</a><a class=\"github-icon-link\" href=\"https://github.com/guaka/signstr\" aria-label=\"GitHub repository\">" + github_mark + "</a></nav>"),
    "</header>",
    "<main>",
    "<section class=\"hero\">",
    "<h1>A Nostr signer<br><em>for iPhone and Mac.</em></h1>",
    "<p>Store Nostr keys on your device, pair clients over NIP-46, and grant each client only the permissions you want.</p>",
    "<div class=\"hero-actions\"><a class=\"primary-action\" href=\"#nip46-test\">Test NIP-46</a><a class=\"secondary-action\" href=\"#how-it-works\">See how it works</a></div>",
    "</section>",
    "<section class=\"product-grid\" id=\"how-it-works\">",
    "<article class=\"product-card feature-card\"><span class=\"card-number\">01</span><div><span class=\"section-kicker\">Keys</span><h2>Add a key</h2><p>Generate a key or import an existing <code>nsec</code>. Signstr stores private keys in the system Keychain.</p></div></article>",
    "<article class=\"product-card\"><span class=\"card-number\">02</span><span class=\"section-kicker\">Connections</span><h3>Pair a client</h3><p>Scan a Nostr Connect code on iPhone or paste its link on Mac. NIP-46 and NIP-55 are supported.</p></article>",
    "<article class=\"product-card\"><span class=\"card-number\">03</span><span class=\"section-kicker\">Requests</span><h3>Approve or reject</h3><p>Review each request and optionally remember a permission for that client.</p></article>",
    "</section>",
    "<section class=\"security-callout\"><div><span class=\"section-kicker\">Key storage</span><h2>Keys stay in the device-only Keychain.</h2></div><p>Private keys are stored as biometric-protected Keychain items. Touch ID, Face ID, or the device passcode gates access before a secp256k1 operation runs in memory.</p></section>",
    "<section class=\"nip46-section section-block\" id=\"nip46-test\">",
    "<div class=\"section-heading nip46-heading\"><div><span class=\"section-kicker\">Interactive protocol lab</span><h2>See NIP-46<br><em>in motion.</em></h2></div><p>Create a disposable test client, pair it with Signstr, and watch an encrypted public-key request make the round trip through Nostr relays.</p></div>",
    "<div class=\"protocol-flow\" aria-label=\"NIP-46 connection flow\">",
    "<div class=\"flow-node\" data-flow-step=\"relay\"><span>1</span><strong>Web client</strong><small>Creates a temporary key</small></div><div class=\"flow-arrow\" aria-hidden=\"true\">→</div>",
    "<div class=\"flow-node\" data-flow-step=\"approval\"><span>2</span><strong>Nostr relay</strong><small>Carries encrypted events</small></div><div class=\"flow-arrow\" aria-hidden=\"true\">→</div>",
    "<div class=\"flow-node\" data-flow-step=\"connected\"><span>3</span><strong>Signstr</strong><small>You review and approve</small></div><div class=\"flow-arrow return-arrow\" aria-hidden=\"true\">←</div>",
    "<div class=\"flow-node\" data-flow-step=\"public-key\"><span>4</span><strong>Encrypted reply</strong><small>Authenticated by its secret</small></div><div class=\"flow-arrow\" aria-hidden=\"true\">→</div>",
    "<div class=\"flow-node\" data-flow-step=\"success\"><span>5</span><strong>Your npub</strong><small>Public key only</small></div>",
    "</div>",
    "<div class=\"tester-shell\">",
    "<div class=\"tester-intro\" id=\"nip46-intro\"><div><span class=\"tester-overline\">Safe to experiment</span><h3>Pair this page with Signstr.</h3><p>The page generates a disposable client key in your browser. It is kept only in memory and disappears when you reset or close the tab.</p></div><button class=\"primary-action tester-start\" id=\"nip46-start\" type=\"button\">Start NIP-46 test</button></div>",
    "<div class=\"tester-panel\" id=\"nip46-panel\" hidden>",
    "<div class=\"tester-toolbar\"><div class=\"tester-live-status\"><span class=\"tester-status-dot\" id=\"nip46-status-dot\"></span><strong id=\"nip46-status-text\" aria-live=\"polite\">Ready to begin</strong></div><div class=\"tester-meta\"><span>Expires <strong id=\"nip46-countdown\">—</strong></span><button id=\"nip46-reset\" type=\"button\">Reset</button></div></div>",
    "<div class=\"tester-grid\">",
    "<div class=\"pairing-card\"><div class=\"qr-frame\"><canvas id=\"nip46-qr\" width=\"272\" height=\"272\" aria-label=\"Nostr Connect QR code\"></canvas></div><div class=\"pairing-actions\"><a class=\"primary-action\" id=\"nip46-open-link\" href=\"#\">Open in Signstr</a><button class=\"secondary-action\" id=\"nip46-copy-link\" type=\"button\">Copy link</button></div><a class=\"raw-connect-link\" id=\"nip46-raw-link\" href=\"#\">Open raw nostrconnect:// link</a></div>",
    "<div class=\"pairing-guide\"><span class=\"tester-overline\">Pairing instructions</span><h3>Scan, approve, then approve once more.</h3><ol><li><span>1</span><div><strong>Open the connection</strong><p>Scan the QR in Signstr, or use the button on this device.</p></div></li><li><span>2</span><div><strong>Approve the app connection</strong><p>Check the client name and relays shown by Signstr.</p></div></li><li><span>3</span><div><strong>Approve “Read public key”</strong><p>The page asks for your public <code>npub</code>—never your private key.</p></div></li></ol><label for=\"nip46-link-value\">Nostr Connect link</label><textarea id=\"nip46-link-value\" rows=\"3\" readonly></textarea><dl class=\"connection-facts\"><div><dt>Temporary client</dt><dd id=\"nip46-client-key\">—</dd></div><div><dt>Relays</dt><dd id=\"nip46-relays\">—</dd></div></dl></div>",
    "</div>",
    "<ol class=\"tester-steps\" aria-label=\"Connection status\"><li data-test-step=\"relay\"><span></span>Relays ready</li><li data-test-step=\"approval\"><span></span>Connection approved</li><li data-test-step=\"connected\"><span></span>Pairing verified</li><li data-test-step=\"public-key\"><span></span>Public key approved</li><li data-test-step=\"success\"><span></span>npub received</li></ol>",
    "<div class=\"tester-success\" id=\"nip46-success\" hidden><div class=\"success-mark\">✓</div><div><span class=\"tester-overline\">NIP-46 connected</span><h3>Your public Nostr identity</h3><p id=\"nip46-npub\" class=\"npub-value\"></p><details><summary>Show hex public key</summary><code id=\"nip46-hex-pubkey\"></code></details></div><button class=\"secondary-action\" id=\"nip46-copy-npub\" type=\"button\">Copy npub</button></div>",
    "<div class=\"tester-error\" id=\"nip46-error\" role=\"alert\" hidden><div><strong>The test could not finish</strong><p id=\"nip46-error-text\"></p></div><button class=\"secondary-action\" id=\"nip46-retry\" type=\"button\">Try again</button></div>",
    "</div>",
    "<p class=\"tester-privacy\"><span aria-hidden=\"true\">◉</span> Your temporary client key stays in this tab. Relays see encrypted NIP-46 events and public routing metadata; they never receive your private Nostr key.</p>",
    "</section>",
    "<section class=\"coverage-intro\" id=\"coverage\">",
    "<div class=\"eyebrow\"><span></span> main branch · built \($generated) UTC</div>",
    "<div class=\"section-heading\"><p>SignstrCore test coverage from the latest successful main build.</p></div>",
    "</section>",
    "<section class=\"metrics\" aria-label=\"Coverage totals\">",
    metric_card("Line coverage"; $lines; "Executable source lines reached by tests."),
    metric_card("Function coverage"; $functions; "Functions entered at least once."),
    metric_card("Region coverage"; $regions; "Control-flow regions exercised."),
    "</section>",
    "<section class=\"section-block\">",
    "<div class=\"section-heading\"><div><span class=\"section-kicker\">Architecture</span><h2>Coverage by area</h2></div><p>SignstrCore only. Tests, generated files, and third-party dependencies are excluded.</p></div>",
    "<div class=\"area-grid\">"
] + (
    $areas
    | map(
        . as $area
        | (metric_sum($area; "lines")) as $metric
        | "<article class=\"area-card\"><div><span>\(($area[0].relative | split("/")[0]) | html_escape)</span><strong>\(percentage($metric))</strong></div><div class=\"progress \(tone($metric))\"><span style=\"width: \(percentage($metric))\"></span></div><small>\($metric.covered) / \($metric.count) lines</small></article>"
    )
) + [
    "</div>",
    "</section>",
    "<section class=\"section-block\" id=\"files\">",
    "<div class=\"section-heading\"><div><span class=\"section-kicker\">Annotated source</span><h2>Every measured file</h2></div><p>Lower-covered files appear first, making the next testing opportunities easy to spot.</p></div>",
    "<div class=\"file-table-wrap\"><table class=\"file-table\"><thead><tr><th>Source file</th><th>Lines</th><th>Functions</th><th>Regions</th></tr></thead><tbody>"
] + (
    $files
    | sort_by(.summary.lines.percent, .relative)
    | map(
        .summary.lines as $lines
        | .summary.functions as $functions
        | .summary.regions as $regions
        | "<tr><td><a href=\"coverage\(.filename).html\"><span class=\"file-area\">\((.relative | split("/")[0]) | html_escape)</span><strong>\((.relative | html_escape))</strong></a></td>"
        + "<td><div class=\"table-metric\"><strong>\(percentage($lines))</strong><small>\($lines.covered) / \($lines.count)</small><div class=\"progress \(tone($lines))\"><span style=\"width: \(percentage($lines))\"></span></div></div></td>"
        + "<td><div class=\"table-metric\"><strong>\(percentage($functions))</strong><small>\($functions.covered) / \($functions.count)</small><div class=\"progress \(tone($functions))\"><span style=\"width: \(percentage($functions))\"></span></div></div></td>"
        + "<td><div class=\"table-metric\"><strong>\(percentage($regions))</strong><small>\($regions.covered) / \($regions.count)</small><div class=\"progress \(tone($regions))\"><span style=\"width: \(percentage($regions))\"></span></div></div></td></tr>"
    )
) + [
    "</tbody></table></div>",
    "</section>",
    "</main>",
    "<footer><div class=\"footer-brand\"><img src=\"signstr-icon.png\" alt=\"\"><span><strong>Signstr</strong><small>Nostr signer for iPhone and Mac</small></span></div><p>Build \($generated) UTC · <a href=\"coverage.json\">Raw coverage data</a> · SwiftPM + llvm-cov · <a href=\"https://github.com/guaka/signstr/blob/main/LICENSE\">AGPL-3.0</a></p></footer>",
    "<script type=\"module\" src=\"nip46-tester.mjs\"></script>",
    "</body>",
    "</html>"
]
| .[]
