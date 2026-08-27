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
    if percentage_number($metric) >= 90 then "excellent"
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
    ("<nav><a href=\"#how-it-works\">How it works</a><a href=\"#coverage\">Coverage</a><a class=\"github-icon-link\" href=\"https://github.com/guaka/signstr\" aria-label=\"GitHub repository\">" + github_mark + "</a></nav>"),
    "</header>",
    "<main>",
    "<section class=\"hero\">",
    "<div class=\"eyebrow\"><span></span> Native on iPhone and Mac</div>",
    "<h1>Your keys.<br><em>Your consent.</em></h1>",
    "<p>Signstr is a Nostr signer that keeps your private key on your device and puts every signing request in front of you.</p>",
    "<div class=\"hero-actions\"><a class=\"primary-action\" href=\"#how-it-works\">See how it works</a><a class=\"secondary-action\" href=\"https://github.com/guaka/signstr\">View source on GitHub</a></div>",
    "</section>",
    "<section class=\"product-grid\" id=\"how-it-works\">",
    "<article class=\"product-card feature-card\"><span class=\"card-number\">01</span><div><span class=\"section-kicker\">Bring your identity</span><h2>Create or import a key</h2><p>Generate a new Nostr key in Signstr or import an existing <code>nsec</code>. Your shareable <code>npub</code> identifies you; your private key stays secret.</p></div></article>",
    "<article class=\"product-card\"><span class=\"card-number\">02</span><span class=\"section-kicker\">Connect your apps</span><h3>Pair through Nostr Connect</h3><p>Scan a connection code on iPhone or paste its link on Mac. Signstr supports NIP-46 remote signing and NIP-55 app requests.</p></article>",
    "<article class=\"product-card\"><span class=\"card-number\">03</span><span class=\"section-kicker\">Stay in control</span><h3>Review every request</h3><p>Read what an app wants to do, choose what to approve, and keep remembered permissions scoped to that app.</p></article>",
    "</section>",
    "<section class=\"security-callout\"><div><span class=\"section-kicker\">Device-first security</span><h2>Protected by the system you already trust.</h2></div><p>Private keys are stored as biometric-protected Keychain items. Touch ID, Face ID, or the device passcode gates access before Signstr performs a secp256k1 operation in memory.</p></section>",
    "<section class=\"coverage-intro\" id=\"coverage\">",
    "<div class=\"eyebrow\"><span></span> main branch · \($generated)</div>",
    "<div class=\"section-heading\"><div><span class=\"section-kicker\">Open engineering</span><h2>Confidence,<br><em>file by file.</em></h2></div><p>Live SignstrCore test coverage from the latest successful main build. Open any source file to see exactly which lines are exercised.</p></div>",
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
    "<div class=\"file-table-wrap\"><table class=\"file-table\"><thead><tr><th>Source file</th><th>Lines covered</th><th>Coverage</th></tr></thead><tbody>"
] + (
    $files
    | sort_by(.summary.lines.percent, .relative)
    | map(
        .summary.lines as $metric
        | "<tr><td><a href=\"coverage\(.filename).html\"><span class=\"file-area\">\((.relative | split("/")[0]) | html_escape)</span><strong>\((.relative | html_escape))</strong></a></td><td>\($metric.covered) / \($metric.count)</td><td><div class=\"table-coverage\"><div class=\"progress \(tone($metric))\"><span style=\"width: \(percentage($metric))\"></span></div><strong>\(percentage($metric))</strong></div></td></tr>"
    )
) + [
    "</tbody></table></div>",
    "</section>",
    "<section class=\"run-callout\"><div><span class=\"section-kicker\">Build Signstr</span><h2>Run the apps locally.</h2><p>Open <code>Signstr.xcodeproj</code> and select the <code>Signstr</code> iOS scheme or <code>SignstrMac</code> macOS scheme.</p></div><a class=\"primary-action\" href=\"https://github.com/guaka/signstr\">Get the source</a></section>",
    "</main>",
    "<footer><div class=\"footer-brand\"><img src=\"signstr-icon.png\" alt=\"\"><span><strong>Signstr</strong><small>Your keys. Your consent.</small></span></div><p><a href=\"coverage.json\">Raw coverage data</a> · Generated with SwiftPM and llvm-cov.</p></footer>",
    "</body>",
    "</html>"
]
| .[]
