# TDZStatus

TDZStatus is a native macOS menu bar companion for ZCode, Claude, and ChatGPT Codex. It brings live harness activity and provider quota snapshots into one polished popover.

## Current build

- Detects whether ZCode, Claude, or ChatGPT/Codex is open and lets the menu bar animation follow a harness, cycle active harnesses, or stay on a selected logo.
- Preserves manual thinking, tool-running, and seven-second alternating animation modes.
- Reads ZCode's cached plan quota locally and the local OmniRoute SQLite database in read-only mode. The OmniRoute query is limited to provider/account display labels and latest quota snapshot fields; it never reads API keys, access or refresh tokens, cookies, ID tokens, or provider credential blobs.
- Shows a direct account view for single-account providers and a combined average only where several accounts share a provider. Every available reset shows both a relative time and the exact timestamp.
- Collapses Google Antigravity into its two meaningful shared weekly pools: Gemini and all other models. NVIDIA connections are identified as unmetered when the provider exposes no measurable quota.
- Treats GitHub Copilot Chat and Completions as unavailable when OmniRoute reports a non-exhausted zero value, avoiding false empty bars.
- Reads official ChatGPT Codex rate limits through the documented local Codex app-server account and rate-limit methods. It displays provider-reported percentages and reset timestamps when a ChatGPT account is available to the Codex profile.
- Reads the Codex config's active and declared model providers and shows which configured providers do not appear in OmniRoute.
- Can fetch Codex Reset's public global 24-hour and 48-hour reset probabilities when enabled. It polls at most once per minute, displays a source link beside the data, and keeps that forecast separate from personal official reset windows.
- Reuses the ZCode/Claude and Codex status animations from the existing companion projects.

The app starts with a connection screen and checks the default local OmniRoute database at `~/.omniroute/storage.sqlite`. It does not change OmniRoute data or install harness hooks. Existing CodexStatus hook markers are read if they are present. Open-app detection works without hooks; detailed thinking/tool activity requires lifecycle markers.

When Codex routes through OmniRoute, TDZStatus surfaces active OmniRoute connections without quota snapshots as dashboard-cookie candidates. xKiro has a ready-to-use dashboard preset that reads its free-model daily allowance, limit, and reset. Custom sources support HTTPS endpoints with percentage or used-and-limit response fields. The cookie is stored in macOS Keychain, and the fetcher blocks redirects to a different host.

## Build and launch

```sh
./build.sh
open TDZStatus.app
```

Or use `./install.sh` to copy the built app to `~/Applications/TDZStatus.app` and open it.

## OpenAI usage source

TDZStatus uses Codex app-server `account/read` and `account/rateLimits/read` for official ChatGPT rate-limit windows. The displayed `usedPercent`, window duration, and reset timestamp are the values returned by Codex. If the connected profile uses only an API key or a custom provider, ChatGPT plan limits may not be available.

The optional Codex Reset view reads the documented `GET /api/forecast` endpoint and is labeled as a global community forecast. It is not an account-specific reset predictor. TDZStatus identifies itself in the request and credits codex-reset.com beside the forecast.

## Security and scope

TDZStatus stores interface preferences in standard macOS app preferences. It does not copy or export OmniRoute credentials. The Codex bridge delegates authentication to the local Codex app-server and returns only an account label, plan type, usage windows, and reset times to the app.
