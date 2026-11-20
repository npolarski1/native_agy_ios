# Existing Apps & Ecosystem Research

Before building **Antigravity Monitor** (`native_agy_ios`), we audited the official Google Antigravity distribution channels, the open-source GitHub ecosystem, and third-party iOS App Store offerings to answer one question:

> **Does an official or free, open-source, self-hosted native iOS app exist for remote monitoring of Google Antigravity 2.0?**

**Short answer: No.** As of 2026, Google does not ship a native iOS app on the App Store, open-source community projects target web PWAs or Android/Flutter, and the few native iOS apps on the App Store are closed-source, commercial/ad-supported, or rely on proprietary third-party relays.

---

## 1. Official Google Status

Google officially distributes Antigravity across:

- **Desktop applications** (macOS, Windows, Linux)
- **CLI** (`agy`) and **Antigravity IDE**
- **Android** mobile client

For **iOS / iPadOS**, Google does **not** offer an official native iOS application on the Apple App Store. Instead, iOS users are directed to **Antigravity Remote Control** as a **web application / PWA** hosted at `antigravity.google` via Safari ("Add to Home Screen").

While a Safari PWA works for basic remote access, iOS platform constraints prevent web apps from delivering first-class native monitoring:

- No **Dynamic Island** or **Lock Screen Live Activities** (`ActivityKit`)
- No **Home Screen Widgets** (`WidgetKit`)
- No **Bonjour / mDNS local network discovery** (`NWBrowser`)
- No **iOS Keychain** token storage or native camera QR deep-link pairing
- No **native actionable notifications** for one-tap remote `PreToolUse` Allow/Deny approvals

---

## 2. Open-Source GitHub Ecosystem

The community has built several useful remote-monitoring and mobile-proxy tools around Antigravity, falling into two categories — **none** of which is a native SwiftUI iOS client:

### Web Dashboards, PWAs & Proxies

| Repository | Architecture | Notes |
| --- | --- | --- |
| `tysonnbt/Antigravity-Deck` | Web dashboard / PWA | Browser-based remote control & dashboard |
| `AFSlayer/antigravity-server` | Server / web interface | Self-hosted web remote server |
| `the-future-company/ag2r` | Web remote bridge | Browser remote interface for Antigravity |
| `EvanDbg/antigravity-remote-dev` | Web remote dev UI | Browser-based remote development monitor |
| `krishnakanthb13/antigravity_phone_chat` | Mobile web chat UI | Phone-friendly browser chat client |
| `L1M80/porta` | Web / remote portal | Remote web access layer |
| `Belal33/antigravity-mobile-proxy` | Mobile web proxy | Proxy serving mobile browser clients |

### Android / Cross-Platform Clients

| Repository | Architecture | Notes |
| --- | --- | --- |
| `AvenalJ/AntigravityMobile` | Android / Flutter client | Focused on Android / cross-platform UI, not native SwiftUI iOS |
| `mohgomaa-art/Antigravity-Mobile` | Android / Flutter client | Focused on Android / cross-platform UI, not native SwiftUI iOS |

**Ecosystem gap:** No free, MIT-licensed, self-hosted, native SwiftUI iOS 17+ application existed for Antigravity 2.0 with Live Activities, WidgetKit, Bonjour discovery, and official Antigravity Hooks integration.

---

## 3. Closed-Source Third-Party App Store Apps

Several third-party commercial apps on the iOS App Store target Antigravity or general AI coding-agent monitoring. Each involves trade-offs around closed source, monetization, or third-party infrastructure:

| App | Developer | Model & Caveats |
| --- | --- | --- |
| **ZeroG: Remote for Antigravity** | Akiva Boas | Closed-source; ad-supported with paid **ZeroG Pro** in-app purchase; requires a third-party relay service and an IDE bridge extension. |
| **Mobile IDE for Antigravity AI** | Luch Dev | Closed-source; freemium with paid **Pro** subscription; requires a proprietary **Antigravity Connector** extension. |
| **Nomo - AI Status & Usage** (`nomo.gg`) | Pok Man Li | Closed-source multi-provider status & usage tracker; live coding agent sessions on Lock Screen / Dynamic Island require paid **Nomo Pro** ($4.99/mo or $34.99/yr). |

For developers who handle proprietary source code, sensitive terminal output, or private prompts — or who simply want a transparent, zero-cost tool they can inspect and build themselves — sending agent sessions through closed-source binaries or third-party cloud relays is often unacceptable.

---

## 4. Comparison Matrix

| Capability | Google Official (`antigravity.google`) | Open-Source Web PWAs | Closed-Source App Store Apps | **Antigravity Monitor (`native_agy_ios`)** |
| --- | :---: | :---: | :---: | :---: |
| Native SwiftUI iOS 17+ App | No (Safari PWA) | No (Web / Android) | Yes | **Yes** |
| 100% Free & Open-Source (MIT) | No | Yes | No (Ads / IAP / Pro) | **Yes** |
| Self-Hosted (Zero 3rd-Party Relays) | Cloud | Usually | Often 3rd-party relay | **Yes (LAN / Tailscale / Tunnel)** |
| Dynamic Island & Lock Screen Live Activities | No | No | Paid (e.g., Nomo Pro) | **Yes (Free, ActivityKit)** |
| Home Screen Widgets (WidgetKit) | No | No | Varies / Paid | **Yes (Small & Medium)** |
| Interactive `PreToolUse` Allow/Deny Gating | N/A | Varies | Proprietary connector | **Yes (Official Antigravity Hooks)** |
| Zero-Dependency Companion Bridge | N/A | Often Node/npm/Docker | Proprietary extension | **Yes (Pure Python 3.10+ stdlib)** |
| Uses Only Documented Sanctioned Interfaces | Official | Often scrapes/patches | Proprietary extensions | **Yes (Brain files + Official Hooks)** |

---

## 5. Why Antigravity Monitor Exists

**Antigravity Monitor** fills this gap cleanly with four core principles:

1. **100% Free & Open-Source (MIT)**: No subscriptions, no in-app purchases, no ads, no analytics, and no third-party cloud relay sitting between your workstation and your phone.
2. **Strictly Sanctioned Antigravity 2.0 Interfaces**:
   - Reads Antigravity's documented `~/.gemini/antigravity/brain/<conversation-id>/` workspace transcripts (`transcript.jsonl`, `transcript_full.jsonl`), artifacts, and background task logs (`.system_generated/tasks/*.log`).
   - Integrates with **Official Antigravity Hooks** (`~/.gemini/config/hooks.json` or `.agents/hooks.json`) for real-time lifecycle notifications (`PreInvocation`, `PostInvocation`, `PostToolUse`, `Stop`) and interactive **`PreToolUse` Allow/Deny tool gating** from your iPhone.
   - Never patches binaries, injects into IDE processes, or relies on undocumented private endpoints.
3. **Zero-Dependency Companion Bridge (`bridge/`)**: Written entirely in Python 3.10+ standard library (pure `asyncio` HTTP/1.1 + RFC 6455 WebSocket server, pure-Python terminal QR code generator, optional Bonjour `_antigravity-mon._tcp` advertising). Runs out of the box on Windows, macOS, and Linux without `pip install` or Node.js.
4. **Genuinely Native iOS 17+ Experience (`ios/`)**: Built in Swift 5.10 & SwiftUI with Keychain token storage, camera QR pairing (`agymon://pair?...`), Bonjour LAN discovery, actionable push/local approval notifications, WidgetKit Home Screen widgets, and ActivityKit Dynamic Island Live Activities.
