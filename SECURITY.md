# Security Policy

Signstr handles Nostr private keys and signing requests. Please report suspected
vulnerabilities privately so they can be investigated before details become
public.

## Supported Versions

Signstr is currently pre-1.0. Before the first tagged release, security fixes
are made on `main`. After releases begin, only the latest tagged release is
supported; users may need to upgrade to receive a fix.

| Version | Supported |
| --- | --- |
| `main` before the first release | Yes |
| Latest tagged release | Yes |
| Earlier tagged releases | No |

## Reporting a Vulnerability

Use [GitHub's private vulnerability reporting](https://github.com/guaka/signstr/security/advisories/new)
to contact the maintainers. Do not open a public issue or discussion for a
suspected vulnerability.

Please include as much of the following as you can:

- A description of the vulnerability and its potential impact.
- The affected Signstr version or commit.
- The device, operating system, and app target (iOS or macOS).
- Reproduction steps or a minimal proof of concept.
- Any known mitigations or workarounds.

Never include a real Nostr private key (`nsec`), seed phrase, signing
credential, authentication token, or private relay content. Use disposable test
keys and redact logs and screenshots.

We generally acknowledge reports within seven days, although response times may
vary. We will investigate, keep the reporter informed of material progress, and
coordinate a disclosure date when a fix is ready. If a report is not accepted
as a vulnerability, we will explain why. Reporters will be credited in the
advisory when appropriate unless they prefer to remain anonymous. Signstr does
not currently offer a bug bounty.

For ordinary bugs and feature requests that do not have security implications,
use the project's public issue tracker.
