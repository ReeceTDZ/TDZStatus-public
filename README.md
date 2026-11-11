# TDZStatus

TDZStatus is a native macOS menu bar companion for ZCode, Claude, and ChatGPT Codex. It brings live harness activity and provider quota snapshots into one polished popover.

## Current build

- Detects whether ZCode, Claude, or ChatGPT/Codex is open and lets the menu bar animation follow a harness, cycle active harnesses, or stay on a selected logo.
- Preserves manual thinking, tool-running, and seven-second alternating animation modes.
- Reads ZCode's cached plan quota locally and the local OmniRoute SQLite database in read-only mode. The OmniRoute query is limited to provider/account display labels and latest quota snapshot fields; it never reads API keys, access or refresh tokens, cookies, ID tokens, or provider credential blobs.
- Shows a direct account view for single-account providers and a combined average only where several accounts share a provider. Every available reset shows both a relative time and the exact timestamp.
- Lists all OmniRoute Codex accounts, including disabled connections and their last saved usage snapshots. A compact, optional global Codex reset estimate based on public OpenAI staff signals can appear under the provider accounts.
- Lists enabled and disabled accounts for every provider. Expand a provider card to enable or disable an account; TDZStatus sends the status change to OmniRoute's authenticated dashboard API and reloads the account state from its local database. Disabled accounts remain visible and contribute their most recently saved readings to combined averages.
- Collapses Google Antigravity into its two meaningful shared weekly pools: Gemini and all other models. Cline and NVIDIA are excluded from provider usage views.
- Treats GitHub Copilot Chat and Completions as unavailable when OmniRoute reports a non-exhausted zero value, avoiding false empty bars.
- Reads official ChatGPT Codex rate limits through the documented local Codex app-server account and rate-limit methods. It displays provider-reported percentages and reset timestamps when a ChatGPT account is available to the Codex profile.
- Reads the Codex config's active and declared model providers and shows which configured providers do not appear in OmniRoute.
- Can fetch Codex Reset's public global 24-hour and 48-hour reset probabilities when enabled. It polls at most once per minute, displays a source link beside the data, and keeps that forecast separate from personal official reset windows.
- Reuses the ZCode/Claude and Codex status animations from the existing companion projects.
- Adds the legacy session controls: task-finished notifications, near-limit alerts, Launch at Login, Code Sleep, Pause Other Apps, and phone-hotspot auto-connect. Code Sleep holds system-sleep assertions while a harness is active; optional paused apps resume when activity ends or TDZStatus quits.
- Includes Codex turn token totals in completion alerts when its local `token_count` records are available. The reader parses only numeric token usage fields and skips prompt, assistant, and tool records. Usage percentages are included when a recent quota snapshot is available.
- Keeps the OpenAI staff reset estimate inside the Codex provider card, after the Codex account details, with relative and calendar estimates.
- Makes manual refresh request fresh provider limits from the local OmniRoute dashboard, then watches the read-only SQLite snapshots for new rows before reporting the refresh complete. The local dashboard cookie is stored in Keychain and sent only to localhost.
- Closes the menu popover when it loses app focus, including when you click into another app.

The app starts with a connection screen and checks the default local OmniRoute database at `~/.omniroute/storage.sqlite`. Usage snapshots are queried read-only; account enable/disable actions go through OmniRoute's authenticated dashboard API. TDZStatus does not install harness hooks. Existing CodexStatus hook markers are read if they are present. Open-app detection works without hooks; detailed thinking/tool activity requires lifecycle markers.

When Codex routes through OmniRoute, TDZStatus surfaces connections without quota snapshots as dashboard-cookie candidates. AgentRouter and Token Harbor have dashboard presets. Custom sources support HTTPS endpoints with percentage or used-and-limit response fields. The cookie is stored in macOS Keychain, and the fetcher blocks redirects to a different host.

Phone hotspot credentials are also stored in macOS Keychain. Automatic reconnect is attempted when macOS reports that the network path is unavailable. Notification and usage-warning preferences are independent; near-limit alerts begin at 90% usage and are sent once for each reset window.

## Build and launch

```sh
./build.sh
open "TDZStatus Public.app"
```

Or use `./install.sh` to copy the built app to `~/Applications/TDZStatus Public.app` and open it.

## OpenAI usage source

TDZStatus uses Codex app-server `account/read` and `account/rateLimits/read` for official ChatGPT rate-limit windows. The displayed `usedPercent`, window duration, and reset timestamp are the values returned by Codex. If the connected profile uses only an API key or a custom provider, ChatGPT plan limits may not be available.

The optional Codex Reset view reads the documented `GET /api/forecast` endpoint and is labeled as a global community forecast. It is not an account-specific reset predictor. TDZStatus identifies itself in the request and credits codex-reset.com beside the forecast.

## Security and scope

TDZStatus stores interface preferences in standard macOS app preferences. It does not copy or export OmniRoute credentials. The Codex bridge delegates authentication to the local Codex app-server and returns only an account label, plan type, usage windows, and reset times to the app.

## Updating without reconnecting

The public copy uses its own bundle identifier, preferences, Keychain services, session folder, and `TDZStatus Public.app` install path. It requires its own dashboard connections. It does not overwrite an existing TDZStatus installation or its credentials.

## Codex limits and estimates

The combined primary reading averages the latest available primary reading per Codex account, including disabled accounts. Accounts with no reading are excluded, and the coverage is shown. Different accounts may have different reset dates and plan capacities, so percentages are not a sum of absolute quotas.

Provider-reported five-hour sessions and paid weekly limits are labelled as official. When those windows are unavailable on free accounts, the app can estimate a five-hour or seven-day spending budget from recent snapshots, remaining primary allowance, and time until the provider reset. These are rolling budget estimates, not OpenAI limits; they have no provider reset timestamp. At least 4½ hours of history is needed for the five-hour estimate and at least six days for the weekly estimate; stale or missing readings show as unavailable.
