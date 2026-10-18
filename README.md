# PennyBar

A macOS menu bar app that shows this billing period's spend across usage-billed services:
Cloudflare, Vercel, Railway, Neon and PlanetScale. Requires macOS 26.

## Build and run

```sh
swift test                 # unit tests for providers and cost math
scripts/bundle.sh          # builds build/PennyBar.app (ad-hoc signed)
open build/PennyBar.app
swift run PennyBar --render-previews previews   # debug: render UI states with sample data to PNGs
```

Open **Settings…** from the menu, click **+**, pick a service and paste a token. The billing scope
is looked up and the connection checked automatically. Tokens are stored in the Keychain. The account list and
last snapshots live in `~/Library/Application Support/PennyBar/`.

## Budgets

Set a total budget and per-account budgets in **Settings › Budgets** (or in an account's editor).
Each account's spend is compared with its own budget for its current billing period; the total
budget is compared with the combined spend of the accounts shown in the menu. When any budget
reaches 80% the menu bar icon turns yellow, and once one is reached it becomes a red `!`.

## Where the numbers come from

| Provider | Source | Total |
|---|---|---|
| Cloudflare | `GET /accounts/{id}/billable-usage` (alpha, PayGo only), FOCUS rows | Billed |
| Vercel | `GET /v1/billing/charges`, FOCUS JSONL, calendar month | Billed |
| Railway | GraphQL `workspace.customer.currentUsage` (undocumented); breakdown from `usage` × published rates | Billed, breakdown estimated |
| Neon | `GET /consumption_history/v2/projects` × published Launch/Scale prices | Estimated |
| PlanetScale | `GET /organizations/{org}/invoices` (current-period invoice) + line items, grouped by database | Billed |

Estimated figures are prefixed with `≈` in the UI.

## Architecture

```
Sources/PennyBarCore      provider-neutral, no UI
  Model/                  Money, UsageSnapshot (period, total, CostKind, line items, limit), Account
  Networking/             HTTPClient seam + ProviderError
  Providers/              UsageProvider protocol, ProviderRegistry, FOCUS parser, one file per service
  Storage/                KeychainTokenStore, JSONFileStore
Sources/PennyBar          SwiftUI MenuBarExtra + Settings; AppModel owns accounts and refresh
```

Every provider maps its API into the same `UsageSnapshot`, and the UI only reads that type.
An `Account` is one token plus one billing scope (Cloudflare account, Vercel team, Railway workspace,
Neon org), so multiple accounts per provider work out of the box.

### Adding a provider

1. Create `Sources/PennyBarCore/Providers/FooProvider.swift` that conforms to `UsageProvider`:
   a `ProviderDescriptor` (name, icon, token help), `scopes(token:)` and `snapshot(token:scopeID:now:)`.
   If the service exports FOCUS cost data, reuse `FOCUS.parseJSONLines` / `FOCUS.summarize`.
2. Register it in `ProviderRegistry.standard`.
3. Add tests with `MockHTTPClient` canned responses.

The settings UI, storage and menu need no changes.
