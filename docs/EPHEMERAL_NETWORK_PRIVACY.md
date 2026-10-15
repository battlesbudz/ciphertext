# Network privacy: IP address and timestamp obfuscation

How this fork hides the user's IP address and obscures timing patterns,
what it deliberately does not do, and what remains the user's job.

## Tor (Orbot) — implemented

The app already routes messaging traffic through a SOCKS5 proxy when the
user enables it (Settings → Network & servers → Use SOCKS proxy,
default `localhost:9050` — Orbot's port). The Haskell core speaks SOCKS5
via `hs-socks`, including `.onion` relay hosts.

What this fork adds on top of upstream:

- **Orbot detection**: the Network & servers screen checks whether Orbot
  (`org.torproject.android`) is installed (manifest `<queries>` entry
  makes the check visible on Android 11+).
- **One-tap Tor routing**: if Orbot is installed, "Route through Tor
  (Orbot)" enables the SOCKS proxy with the existing confirm dialog. If
  Orbot is not installed, "Install Orbot to use Tor" opens Orbot's
  install page.

What Tor covers: the messaging servers see the Tor exit node's IP, not
the user's. The ISP sees only Tor traffic (entry node), not which
messaging servers are contacted.

What Tor does NOT cover: the ISP can still see that Tor is being used,
and a global observer correlating traffic at both ends can still attempt
timing correlation (see jitter below). Calls use a direct connection —
this is an upstream limitation, unchanged by this fork.

Tor is OFF by default. Turning it on when Orbot is not installed and
running would break connectivity entirely, so enabling it stays an
explicit user choice.

## Heartbeat jitter — implemented

Live-session heartbeats are the only periodic traffic the app sends.
They were sent on an exact 10 s schedule — a timing beacon. Each
heartbeat send is now delayed by 10 s ± 2 s of uniform random jitter,
so the send times no longer form an exact pattern. Worst-case gap
between peer heartbeats is ~12 s + network latency, far inside the
30 s session timeout, so session liveness is unaffected.

## Padding / cover traffic — NOT implemented

Padding (dummy) messages were considered and deliberately left out:
padding sent as separate messages would still be distinguishable by the
relay (message counts and sizes), while costing battery and bandwidth.
The heartbeat jitter above covers the only periodic signal the app
emits; user messages are already irregular. True cover traffic would
need protocol-level support (constant-rate, same-size messages) and is
out of scope for this prototype.

## VPN — user guidance only, not implemented in-app

A VPN is device-level: the app cannot and does not manage it. If the
user wants ISP-level hiding without Tor, a reputable VPN on the device
hides the user's IP from the messaging servers and hides which servers
are contacted from the ISP — but the VPN provider itself can then see
that traffic. Tor and VPN can be combined; neither is managed by this
app.

## Domain fronting / CDN — does NOT apply

SimpleX connects directly (TCP/TLS) to SMP/XFTP relay servers. There
is no CDN endpoint in front of them, so there is nothing to "front"
behind. Adding one would mean introducing a trusted intermediary that
sees the traffic — the opposite of the goal. Not implemented, and not
planned.

## Summary

| Method | Status |
|---|---|
| Tor via Orbot (SOCKS proxy + one-tap enable) | Implemented |
| Heartbeat jitter (±2 s) | Implemented |
| Padding / cover traffic | Not implemented (see above) |
| VPN | User choice, not app-managed |
| Domain fronting / CDN | Does not apply |

## Still needs on-device verification

- Tor routing end to end on a real phone (Orbot installed + running,
  SOCKS proxy on, messages flow, IP hidden from the relay).
- Heartbeat jitter does not cause spurious session timeouts under poor
  network conditions (worst-case gap stays well under 30 s by design;
  not yet observed on-device).
- The two-phone live test has not run; none of the live behavior in
  this fork is proven on-device yet.
