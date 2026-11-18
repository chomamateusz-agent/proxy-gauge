# CLIProxyAPI monitoring and remote-control API

## Scope and evidence

This is a wire-contract reference for a native client, not a transcription of the panel's normalized TypeScript models. JSON names below are case-sensitive. Paths start at the server origin, before any reverse-proxy mount prefix. Requests with bodies use `Content-Type: application/json` unless stated otherwise; GET requests have no body.

Source prefixes used in `path:line` citations:

- **upstream:** the stock CLIProxyAPI source for release 8.0.69; paths are relative to its repository root.
- **panel:** the official management panel source; paths are relative to its repository root.
- **fleet fork:** a CLIProxyAPI fork on an older 8.0.42 base that adds the fleet extensions below; extensions must be feature-detected.

**Captured** examples and all six files in `fixtures/` are actual responses from the supplied stock binary: version `8.0.69`, commit `f7ae8fee`, build date `2026-11-12T18:27:10Z`. Capture time was 2026-11-13 23:10 UTC. The final fixture run used an empty temporary OAuth directory, no client keys or provider accounts, local embedded model catalogs, and a throwaway management key. The proxy was stopped after probing. Empty response bodies are meaningful, not missing samples.

**Source-derived** examples illustrate populated payloads or successful mutations that could not be captured without real provider accounts. They are not live provider measurements. In particular, no provider OAuth tokens were used and no provider quota request was made. This distinction matters: quota values cannot be honestly captured from an empty account directory.

For decoding, preserve unknown fields and distinguish **omitted**, **null**, **empty array**, and **zero**. Integers representing counters are Go `int64`; decode accordingly. Management `time.Time` values are RFC3339 strings and may contain fractional seconds. Fleet explicitly formatted timestamps use UTC RFC3339 unless noted.

## 1. Authentication, capability detection, and version

### Management key

For all management endpoints below, use either:

```http
Authorization: Bearer <management-key>
```

or:

```http
X-Management-Key: <management-key>
```

`Authorization` wins when nonempty. Bearer is case-insensitive; the handler also accepts a raw Authorization value, but clients should send standard Bearer. A client API key is **not** a management key. Never send management credentials to a provider URL; `/requests/api-call` has a separate nested upstream header map.

The current contract is **`/v8/management`**. **`/v0/management`** remains a legacy compatibility contract, with different routes and config payloads. Replacing `v8` with `v0` while keeping the suffix is not generally valid. The panel uses v8 (`panel: src/utils/connection.ts`, `computeApiUrl`) and Bearer auth (`panel: src/services/api/client.ts:130`). Route registration: `upstream: internal/api/server_management_v8.go:11`; legacy registration: `upstream: internal/api/server_management.go:14`.

Server configuration is `management.allow-remote` and `management.secret-key` in v8 YAML (legacy `remote-management.allow-remote` / `remote-management.secret-key`). Empty secret disables management routes unless an alternate configured/environment/local management secret enables them. `management.disable-control-panel` disables the HTML panel, not the authenticated management API. See `upstream: config.example.yaml:111`, `upstream: internal/api/server.go:256`, `upstream: internal/api/handlers/management/handler.go:324`.

| Condition | HTTP | Body / interpretation |
| --- | --- | --- |
| Management unavailable/disabled, including Home mode | 404 | Availability middleware may return an empty body; an unregistered route may return plain `404 page not found`. Do not require JSON. |
| Non-loopback client while remote management is disallowed | 403 | `{"error":"remote management disabled"}` |
| Authenticator reached with no configured management secret | 403 | `{"error":"remote management key not set"}`; normally hidden behind the 404 availability gate. |
| Missing key | 401 | **Captured:** `{"error":"missing management key"}` |
| Wrong key | 401 | `{"error":"invalid management key"}` |
| IP temporarily banned after five failed attempts | 403 | `{"error":"IP banned due to too many failed attempts. Try again in <duration>"}`; ban is 30 minutes. |

Local means `127.0.0.1` or `::1` as resolved by Gin's client-IP handling; localhost still requires a key. A 404 does not by itself distinguish wrong prefix, disabled management, Home mode, or reverse-proxy routing. Do not repeatedly guess keys: failures share an IP-level ban counter.

Sources: `upstream: internal/api/handlers/management/handler.go:324-459`; `upstream: internal/api/server_management.go:204-227`.

### Installed version versus available update

Management auth middleware supplies these headers, including on its 401/403 responses:

```http
X-CPA-VERSION: 8.0.69
X-CPA-COMMIT: f7ae8fee
X-CPA-BUILD-DATE: 2026-11-12T18:27:10Z
X-CPA-SUPPORT-PLUGIN: 1
```

These four values were captured. Header names are case-insensitive. Availability-gate 404s precede that middleware and need not have them. `/v1/models` need not carry them either. Read the headers from an ordinary management response rather than adding a version request. Source: `upstream: internal/api/handlers/management/handler.go:324-330`.

`GET /v8/management/server/latest-version` (legacy `GET /v0/management/latest-version`) returns `{"latest-version":"<release-tag>"}`. It checks **GitHub's latest release**, not the installed version, with a 10-second HTTP timeout. Failures include 502 with `error` and `message`. Do not poll it on every refresh. Sources: `upstream: internal/api/server_management_v8.go:29`; `upstream: internal/api/handlers/management/config_basic.go:21-102`.

`GET /healthz` needs no key and returns **captured** `{"status":"ok"}`; `HEAD /healthz` has no body. It proves process HTTP reachability, not valid management credentials or available upstream accounts. Source: `upstream: internal/api/server_routes.go:45-55`.

## 2. Server configuration and basic info

### Read configuration

| Method/path | Request | Response |
| --- | --- | --- |
| `GET /v8/management/config` | None | Raw v8 configuration JSON object, shaped like normalized v8 YAML. Not wrapped in `config`. |
| `GET /v8/management/config/<path>` | Slash-separated YAML keys | Raw selected value: object, array, string, bool, or number. Missing node: 404 `{"error":"not_found"}`. |
| `GET /v8/management/config.yaml` | None | `application/yaml; charset=utf-8`, **not JSON**. |
| `GET /v0/management/config` | None | Legacy config object serialized from the in-memory Go config; do not decode it as the v8 YAML tree. |

V8 GET reads the saved configuration file and normalizes its layout. It does **not** materialize every runtime default: a valid setting can be absent from the saved tree and therefore its subtree read can be 404. An initial minimal configuration without `routing` reproduced this. The existence of `/config` is a better v8 capability probe than a possibly absent leaf.

Useful v8 selections (each is a GET under `/v8/management/config/`):

| Suffix | Shape / purpose |
| --- | --- |
| `server` | Object including configured `host`, `port`, optional `tls`, `commercial-mode`, `response-compression`, etc. |
| `server/port` | Integer. |
| `routing` | Object including configured `strategy`, `session-affinity`, `retry`, etc. |
| `access/api-keys` | Array of inbound client keys; see security warning below. |
| `observability/usage` | Object including configured `usage-statistics-enabled`, `redis-usage-queue-retention-seconds`. |
| `observability/logging` | Object including configured `logging-to-file`, etc. |
| `oauth/auth-dir` | String: the server-side account directory, not a client filesystem path. |

**Captured** `GET /v8/management/config/routing`:

```json
{"strategy":"round-robin"}
```

A successful v8 GET includes `Cache-Control: no-store` and an `ETag` for the entire on-disk config bytes. For writes, retain the ETag and send `If-Match`; stale writes return 412 `{"error":"precondition_failed"}` with the current ETag. A subtree ETag is still for the whole file. V8 writes return `{"config-version":8,"status":"ok"}`. Without `If-Match` they are unconditional. PUT replaces the selected node; PATCH recursively merges objects and replaces lists. Do not round-trip a partially decoded config document, which can discard unknown settings. A successful v8 config write can migrate a legacy config file to v8 layout.

**Sensitive response:** config reads are not a safe diagnostic export. Client keys, provider keys, proxy credentials, and management configuration may be present. Never persist the full payload as a fixture/log. Read only needed subtrees when practical, keep credentials in Keychain, and mask key values in UI. V8 JSON specifically strips ICE server usernames/credentials, not every secret in every subtree.

Sources: routes `upstream: internal/api/server_management_v8.go:20-27`; v8 read/write semantics `upstream: internal/api/handlers/management/config_v8.go:21-85,88-213,360`; legacy config `upstream: internal/api/handlers/management/config_basic.go:26`; tree names `upstream: config.example.yaml:15-32,111-149,177,1033,1279-1306`.

## 3. Accounts / auth files

### List accounts

`GET /v8/management/credentials`

Legacy: `GET /v0/management/auth-files`.

Optional query parameters:

- `name`: exact filename/credential lookup filter.
- `auth_index`: opaque string identity filter; do not parse as a numeric array position.
- `page`, `page_size`: positive integers; supplying either enables pagination. Defaults in that mode: page 1, page size 50. Invalid values return 400. Omitting both returns the full list.

Top-level response:

```text
{
  "observed_at": RFC3339,
  "files": [Account],
  "total": integer,       present only in paginated responses
  "page": integer,        present only in paginated responses
  "page_size": integer,   present only in paginated responses
  "has_more": boolean     present only in paginated responses
}
```

**Captured** (`fixtures/auth-files-empty.json`):

```json
{"files":[],"observed_at":"2026-11-13T23:10:00.063357Z"}
```

Memory-backed `Account` fields emitted by the current source:

| Fields | Exact types / semantics |
| --- | --- |
| `id`, `auth_index`, `name` | Strings. Credential ID, opaque index, filename/display identity. Use returned `name` and optional `auth_index` for mutations. |
| `type`, `provider` | Strings identifying provider; both are emitted. |
| `label`, `status`, `status_message` | Strings. Render status as extensible, not a closed enum. Known statuses include `active`, `disabled`, `error`; cooldown reconciliation can affect displayed status. |
| `disabled`, `unavailable`, `runtime_only` | Booleans; administrative disable, current availability, and virtual/runtime-only identity are different concepts. |
| `source` | String, e.g. `file` or `memory`. |
| `size` | Integer byte count. |
| `success`, `failed` | Integer cumulative credential request counts, **not tokens**. |
| `recent_requests` | Array of `{"time":string,"success":int64,"failed":int64}`. Current source emits 20 ten-minute buckets, oldest first; `time` is a local-server display interval such as `"22:00-22:10"`, not an ISO timestamp. |
| `quota` | Passive observation object: `{"signals":{string:string},"observed_at":RFC3339?}`. Always `signals`, optional `observed_at`; not a ready-made percent/window DTO. |
| `model_quotas` | Optional map: model ID → the same passive observation object. |
| `cooldowns` | Array of `Cooldown` below, or **null** when scheduler cooldowns are not known (Home mode / disk fallback). Empty array means known and none. |

Optional identity/config fields: `email`, `project_id`, `account_type`, `account`, `path`, `note` (strings); `priority`, `weight`, `request_retry` (integers); `websockets` (boolean). `account` can contain an upstream API key: prefer `email`, then `project_id`, then `name` for display. The panel deliberately avoids displaying `account` (`panel: src/services/api/routing.ts:239`).

Optional timestamps: `created_at`, `modtime`, `updated_at`, `last_refresh`, `next_retry_after` (RFC3339). Optional `id_token` is a decoded subset of provider claims, not an instruction to download/store a raw OAuth token. Quota capability fields: `supports_quota` (boolean), `quota_provider` (string), `quota_plugin_id` (v8 plugin string); legacy v0 may also include declarative `quota_probe`.

Current v8-only renewal/health fields are additive:

- Always on memory-backed entries: `requires_sign_in`, `quota_blocked`, `adopted`, `inference_verified`, `renewal_verified` (booleans); `renewal_state`, `recovery_stage` (strings).
- Optional strings/timestamps: `oauth_provider`, `access_token_expires_at`, `next_refresh_after`, `adopted_at`, `last_inference_verified_at`, `last_renewal_verified_at`, `next_action`, `recovery_hint`.
- Optional `refresh_error`: `{"code":string,"message":string,"http_status":integer}`.
- Optional `renewal_event`: `{"type":"renewal_sign_in_required","auth_id":string,"provider":string,"next_action":"sign_in","occurred_at":RFC3339?,"account":string?,"access_token_expires_at":RFC3339?}`.
- Codex-specific: `siwc_bind_supported`, `use_siwc`, `siwc_bound` (booleans), `siwc_status` (string), optional `siwc_expires_at`.

Disk fallback entries are less rich: do not require the memory-only fields in a decoder. Runtime-only disabled credentials can be hidden by the list builder; do not equate list length with the number of credential files on disk.

`Cooldown` schema:

```text
{
  "scope": "credential" | "model",
  "model_key": string?,
  "reason": string,
  "retry_at": RFC3339,
  "remaining_seconds": int64,
  "backoff_level": integer?,
  "http_status": integer?
}
```

`quota.signals` describes provider observations; `cooldowns` describes routing blocks. Do not treat a percent of 100, a stale reset timestamp, or `unavailable` alone as equivalent to every model being blocked. Use the server's `observed_at` to anchor countdowns and display observation freshness.

Sources: routes `upstream: internal/api/server_management_v8.go:44`, `upstream: internal/api/server_management.go:180`; list/filter/pagination `upstream: internal/api/handlers/management/auth_files.go:106-229`; disk fallback `:384`; account construction `:654-868`; quota serialization `:879-916`; buckets `upstream: sdk/cliproxy/auth/types.go:321-340,442-480`; cooldown fields `upstream: sdk/cliproxy/auth/cooldown_view.go:11-18`.

### Enable / disable an account

`PATCH /v8/management/credentials/status`

Legacy: `PATCH /v0/management/auth-files/status`.

Request, **source-derived**:

```json
{"name":"account.json","auth_index":"opaque-index-from-list","disabled":true}
```

`name` and boolean `disabled` are required. `auth_index` is optional but guards identity matching. Send `disabled:false` to enable. Ordinary success is `{"status":"ok","disabled":true}`. For config-backed API keys the result can additionally include `"via":"config:excluded-models","excluded_pattern":"*"`. A plugin virtual child cannot be mutated independently (409); use its source account.

**Captured** request `{"name":"missing.json","disabled":true}` returned HTTP 404 `{"error":"auth file not found"}`. Validation errors are 400; missing core manager is 503. A persistence/synchronization error is 500 and may follow an already-applied change, so refresh before retrying. On success, re-read the list rather than only toggling local UI state.

Sources: `upstream: internal/api/server_management_v8.go:49`; `upstream: internal/api/handlers/management/auth_files_fields.go:30-150`; legacy route `upstream: internal/api/server_management.go:186`.

### Models associated with an account

`GET /v8/management/credentials/models?name=<URL-encoded-name>`

Legacy: `GET /v0/management/auth-files/models?name=...`.

Returns `{"models":[{"id":string,"display_name":string?,"type":string?,"owned_by":string?}]}` from the local model registry. Missing `name`: 400. An unknown name is not necessarily a 404: **captured** `name=missing.json` returned 200 `{"models":[]}`. Cheap local read; useful for an account detail screen, not necessary for every summary refresh.

Sources: `upstream: internal/api/server_management_v8.go:47`; `upstream: internal/api/handlers/management/auth_files.go:336-381`.

## 4. Provider quota windows

There are three distinct mechanisms. Do not invent `/v8/management/credentials/quota` or assume the account-list `quota` field already contains `five_hour` and `seven_day`.

### 4.1 Passive observations (cheap)

Read `quota` and `model_quotas` from the account list. Signals are string-to-string maps containing captured provider header watermarks, with an observation timestamp. Unsupported provider observations serialize as `{"signals":{}}`. These reads do not themselves ask the provider for usage.

The fleet fork turns passive observations into the structured `/v1/fleet/limits` response in section 8. Stock account-list responses expose the observations, not that fleet DTO. Sources: `upstream: internal/api/handlers/management/auth_files.go:879-916`; `fleet fork: sdk/cliproxy/auth/quota_limits.go:46-88`.

### 4.2 Provider HTTP usage via API-call (what built-in panel cards use)

`POST /v8/management/requests/api-call`

Legacy: `POST /v0/management/api-call`.

Request schema (all exact JSON names):

```text
{
  "auth_index": string?,
  "method": string,
  "url": string,
  "proxy_url": string?,
  "header": {string:string}?,
  "data": string?
}
```

`authIndex` and `AuthIndex` are accepted aliases for `auth_index`; use snake_case in new clients. `header` is singular. `data` is a serialized body string, not a nested JSON object. `method` and absolute `url` are required. Literal `$TOKEN$` in header values or `data` is substituted server-side with the selected credential token; the native client never needs to download that token. Selection is by `auth_index`, not filename. `proxy_url` is an optional per-request upstream proxy override.

Response:

```text
{"status_code":integer,"header":{string:[string]},"body":string}
```

The outer status is **200 even if the upstream returned 401, 403, or 429**. Inspect `status_code`; then JSON-decode `body` if appropriate. `body` is always a string on the wire, and headers have array values. The panel's camelCase `statusCode` / parsed body are client-side transformations, not server JSON. Transport/read failures return outer 502 `{"error":"request failed"}` / `{"error":"failed to read response"}`. Bad/missing method/URL/token inputs return outer 400. Token resolution can refresh an OAuth access token.

A real local-only probe called this endpoint with `{"method":"GET","url":"http://127.0.0.1:9010/healthz"}` and returned outer HTTP 200, inner `status_code:200`, `body:"{\"status\":\"ok\"}"`, and `header` containing actual response-header arrays. No provider was contacted in that probe.

Sources: routes `upstream: internal/api/server_management_v8.go:30`, `upstream: internal/api/server_management.go:80`; schemas `upstream: internal/api/handlers/management/api_tools.go:33-48`; transport and errors `:104-250`; panel conversion `panel: src/services/api/apiCall.ts`.

#### Claude OAuth usage

The panel makes two API-call requests: usage and profile. The usage request is **source-derived**, not a captured provider response:

```json
{
  "auth_index":"opaque-index-from-list",
  "method":"GET",
  "url":"https://api.anthropic.com/api/oauth/usage",
  "header":{
    "Authorization":"Bearer $TOKEN$",
    "Content-Type":"application/json",
    "Accept":"application/json",
    "anthropic-beta":"oauth-2025-04-20",
    "User-Agent":"claude-cli/2.1.280 (external, cli)"
  }
}
```

Known fields inside the JSON-decoded response `body`:

```text
{
  "five_hour": {"utilization":number|null,"resets_at":string|null} | null,
  "seven_day": {"utilization":number|null,"resets_at":string|null} | null,
  "seven_day_oauth_apps": Window | null,
  "seven_day_opus": Window | null,
  "seven_day_sonnet": Window | null,
  "seven_day_cowork": Window | null,
  "iguana_necktie": Window | null,
  "limits": [provider-defined scoped limit objects],
  "extra_usage": {
    "is_enabled":boolean?,"monthly_limit":number|null?,
    "used_credits":number|null?,"utilization":number|null?,
    "currency":string?,"disabled_reason":string?,
    "user_disabled":boolean?,"spend_limit_reached":boolean?
  } | null
}
```

All top-level provider keys may be omitted; `Window` has `utilization` and `resets_at` as above, optionally `limit_dollars`, `used_dollars`, `remaining_dollars`. **`utilization` is already used percent (0–100), not a 0–1 fraction.** `five_hour` is 5h, `seven_day*` are weekly (168h). Preserve unknown windows. The panel additionally recognizes a weekly scoped entry in `limits` with `kind:"weekly_scoped"`, `scope.model.display_name`, `percent`, `resets_at`, and `is_active`; it distinguishes a dollar-denominated credit pool from a weekly model cap. Missing data is unknown, not zero.

The optional profile request is GET `https://api.anthropic.com/api/oauth/profile` using the same auth headers. It supplies `account` and `organization` fields, including `organization.rate_limit_tier` for plan naming. That is an additional provider request; skip it if plan naming is not needed.

Sources: `panel: src/utils/quota/constants.ts:100-124`; fetch `panel: src/features/quota/providers/claude/data.ts:208-240`; window interpretation `:50-124`; payload types `panel: src/types/quota.ts:99-174,177-196`; raw normalization `panel: src/services/api/claudeUsage.ts:10-76`.

#### Codex / ChatGPT usage

Use the same API-call endpoint with:

- `method:"GET"`
- `url:"https://chatgpt.com/backend-api/wham/usage"`
- `header.Authorization:"Bearer $TOKEN$"`, `Content-Type:"application/json"`, and the panel's provider-compatible User-Agent.
- Add `Chatgpt-Account-Id` when the credential exposes an account ID (the panel resolves it from the auth entry/decoded claims). Do not confuse it with `auth_index`.

Decoded `body` shape consumed by the panel:

```text
{
  "plan_type": string?,
  "rate_limit": RateLimit|null?,
  "code_review_rate_limit": RateLimit|null?,
  "additional_rate_limits": [{"limit_name":string?,"metered_feature":string?,"rate_limit":RateLimit|null?}]?,
  "credits": {"has_credits":boolean?,"unlimited":boolean?,"balance":string|number|null?}|null?,
  "rate_limit_reset_credits": {"available_count":number|string?,"applicable_available_count":number|string?}|null?
}
RateLimit = {
  "allowed":boolean?,"limit_reached":boolean?,
  "primary_window":UsageWindow|null?,"secondary_window":UsageWindow|null?
}
UsageWindow = {
  "used_percent":number|string?,
  "limit_window_seconds":number|string?,
  "reset_after_seconds":number|string?,
  "reset_at":number|string?
}
```

The panel tolerates camelCase equivalents. `used_percent` is used percent, not fraction. Identify 5h versus weekly using **`limit_window_seconds`** (18000 / 604800), not an unconditional primary=5h/secondary=weekly assumption. `reset_at` may be Unix seconds or a parseable timestamp; relative reset seconds require a sampled-time anchor. The panel also queries subscriptions and reset-credit details, multiplying provider calls. Its reset-credit **consume** action is a paid/credit-affecting provider mutation and must not run as part of refresh or a generic local cooldown reset.

Sources: constants `panel: src/utils/quota/constants.ts:127-143`; requests `panel: src/features/quota/providers/codex/data.ts:307-315,418-454`; window handling `:95-140`; provider payload types `panel: src/types/quota.ts:35-96`; credit consumption versus cooldown reset `panel: src/features/quota/providers/codex/data.ts:493-534`.

#### Other provider cards

Provider quota endpoints are provider-specific, not interchangeable with the two schemas above. The supplied panel has built-in fetchers for Antigravity, Kimi/Kimi International, xAI, Meta, and Devin, alongside generic plugin quotas. For example Kimi uses `/coding/v1/usages`, and Antigravity uses `v1internal:retrieveUserQuotaSummary`; consult each card adapter instead of decoding their bodies as Claude windows. Sources: `panel: src/utils/quota/constants.ts:68-75,146-159`; `panel: src/features/quota/providers/kimi/data.ts:45`; `panel: src/features/quota/providers/antigravity/data.ts:149`; `panel: src/features/quota/providers/xai/data.ts:89`; `panel: src/services/api/devinQuota.ts`, `metaQuota.ts`.

### 4.3 Normalized plugin quota API

| Method/path | Input | Behavior |
| --- | --- | --- |
| `GET /v0/management/quota/providers` | None | `{"providers":[...]}` from registered quota plugins. **Captured:** `{"providers":[]}` with no providers installed. |
| `POST /v0/management/quota/fetch` | `{"auth_index":string,"plugin_id":string?,"provider":string?}` | Calls quota plugin, or legacy declarative `quota_probe`; 501 if unsupported, 404 if auth unknown, 502 if fetch fails. |
| `GET /v8/management/plugins/:id/quota?auth_index=...` | Query index | Fetches quota, **not merely cached data**. |
| `POST /v8/management/plugins/:id/quota` | `{"auth_index":string}` | Same fetch using plugin ID from path. |
| `DELETE /v8/management/plugins/:id/quota?auth_index=...` | Query index (body fallback accepted) | Provider quota reset, then local routing state reset; not an ordinary refresh. |

Provider discovery is exactly `{"providers":[{"plugin_id":string,"provider":string,"display_name":string?,"supported_providers":[string]?,"supports_reset":boolean}]}`. Source: `upstream: internal/pluginhost/quota_provider.go:40-46,72-104`.

Legacy plugin routes also exist as `/v0/management/plugins/:id/quota`. There is no prefix-only v8 equivalent of v0 `/quota/fetch`; current v8 uses plugin-scoped paths. Discover plugin support from each credential's `supports_quota` and `quota_plugin_id`. A successful plugin fetch uses the **camelCase** normalized response tags below (all top-level fields optional):

```text
{
  "subscription":{"plan":string?,"tierName":string?,"tierId":string?},
  "summary":[{"key":string,"label":string,"value":number,"unit":string?,"format":string?,"currency":string?}],
  "serverTimeOffsetMs":int64,
  "groups":[{
    "displayName":string?,
    "buckets":[{"window":string?,"remainingFraction":number,"resetTime":string?,"description":string?}]
  }]
}
```

`remainingFraction` is remaining quota (typically 0–1), unlike provider `utilization`/`used_percent`. Used percent for UI is `(1 - remainingFraction) * 100`; retain the raw value and tolerate provider irregularities. `resetTime` is a string defined by the provider adapter; do not assume it is an integer epoch. `format` supports number/currency, with ISO currency code when applicable. Empty normalized response can be `{}`. A source-derived example is `{"groups":[{"displayName":"Plan","buckets":[{"window":"5h","remainingFraction":0.75,"resetTime":"2026-11-14T04:00:00Z"}]}]}`.

Sources: v0 registrations `upstream: internal/api/server_management.go:38-42,91-93`; v8 registrations `upstream: internal/api/server_management_v8.go:67-69`; request/discovery/fallback `upstream: internal/api/handlers/management/plugin_quota.go:23-134`; plugin fetch `:238-299`; reset `:302-384`; response tags `upstream: sdk/pluginapi/types.go:1808-1813,1837-1841,1861-1867,1894-1911`.

## 5. Reset local cooldown / routing quota state

`POST /v8/management/routing/cooldown/reset`

Legacy: `POST /v0/management/reset-quota`.

Request, **source-derived**:

```json
{"auth_index":"opaque-index-from-list"}
```

Success shape:

```text
{"status":"ok","auth_index":string,"models":[string]}
```

This resets the proxy's routing quota/cooldown state for the selected auth, not the provider's 5h/weekly allocation. It does not consume a provider reset credit. After success, re-read accounts and their cooldowns. `models` identifies affected model keys; tolerate a null array when the Go slice is nil.

**Captured** request `{"auth_index":"missing"}` returned 404 `{"error":"auth not found"}`. Missing index is 400 `{"error":"auth_index is required"}`, unavailable auth manager is 503, reset failure is 500.

Sources: `upstream: internal/api/server_management_v8.go:31`; `upstream: internal/api/server_management.go:89`; `upstream: internal/api/handlers/management/quota.go:28-78`.

Do not substitute `POST /v0/management/quota/reset` or `DELETE /plugins/:id/quota`: those call a provider/plugin reset before clearing routing state. Source: `upstream: internal/api/handlers/management/plugin_quota.go:136-235,339-384`.

## 6. Requests, usage, tokens, and per-key statistics

### Recent upstream API-key/account counters

`GET /v8/management/observability/usage/api-keys`

Legacy: `GET /v0/management/api-key-usage`.

Response is a **bare map**, not `{usage:...}`:

```text
{
  "<provider>": {
    "<base_url>|<upstream_api_key>": {
      "success":int64,
      "failed":int64,
      "recent_requests":[{"time":string,"success":int64,"failed":int64}]
    }
  }
}
```

**Captured:** `{}`. Keys here identify **upstream provider credentials**, not inbound client keys. Provider is lowercased and may be the compatibility-provider name. An empty base URL produces a composite key beginning with `|`. This response can leak raw upstream API keys through object keys; never log it or use it as an unredacted fixture. OAuth account counters are instead in the account list. These counters do not include tokens or per-model totals. Missing core manager returns 503.

Sources: routes `upstream: internal/api/server_management_v8.go:41`, `upstream: internal/api/server_management.go:100`; response and aggregation `upstream: internal/api/handlers/management/api_key_usage.go:12-16,43-139`.

### Usage event queue (tokens and per-model/per-client-key input)

`GET /v8/management/observability/usage/queue?count=<positive-integer>`

Legacy: `GET /v0/management/usage-queue?count=...`.

**Important: this GET POPS/CONSUMES records.** It is not a read-only cumulative usage snapshot. Default `count` is 1; invalid/nonpositive values return 400 `{"error":"count must be a positive integer"}`. Do not poll it from multiple dashboards or enable background consumption without making the loss/ownership behavior clear. Records have finite in-memory retention (`observability.usage.redis-usage-queue-retention-seconds`, template default 60 seconds). The local Redis RESP usage output is disabled in this version's config template.

Response is a **bare array** of queue records. **Captured:** `[]`. Valid queued JSON is returned as JSON; malformed queued bytes are returned as a JSON string, so a robust decoder accepts an object or string per element.

Core generated record fields (actual tags, not a made-up aggregate `usage` object):

```text
{
  "timestamp":RFC3339,"latency_ms":int64,"ttft_ms":int64,
  "source":string,"auth_index":string,
  "client_ip":string,"resolved_client_ip":string,"x_forwarded_for":string,"user_agent":string,
  "tokens":{
    "input_tokens":int64,"output_tokens":int64,"reasoning_tokens":int64,
    "cached_tokens":int64,"cache_read_tokens":int64,"cache_read_tokens_present":boolean,
    "cache_creation_tokens":int64,"total_tokens":int64
  },
  "failed":boolean,"generate":boolean,"stream":boolean,
  "fail":{"status_code":integer,"body":string,"code":string?},
  "accounting_version":integer,
  "token_breakdown":{
    "schema_version":integer,"quality":string,"total_tokens":int64,
    "input":{"total_tokens":int64,"uncached_tokens":int64,"cache_read_tokens":int64,"cache_write_tokens":int64},
    "output":{"total_tokens":int64,"non_reasoning_tokens":int64,"reasoning_tokens":int64},
    "unclassified_tokens":int64
  },
  "provider":string,"executor_type":string,"model":string,"alias":string,
  "endpoint":string,"auth_type":string,"api_key":string,"is_native_key":boolean,
  "request_id":string,"reasoning_effort":string,"service_tier":string
}
```

Optional event fields include `access_token_sha256`, `response_headers`, `access_provider`, `execution_id`, `home_selection`, `trace_id`, `session_id`, `parent_session_id`, `node_kind`, `is_fork`, `is_compaction`, `effective_service_tier`, `response_service_tier`, `upstream_service_tier`, `response_model`, `speed`, `inference_geo`, `cache_details`, `web_search_requests`, `image_count`, `requested_image_details`, `image_details`, `media_counts`, `tool_usage_details`, `iterations`, `cost_details`.

Optional integer token subdivisions include `cache_creation_5m_tokens`, `cache_creation_30m_tokens`, `cache_creation_1h_tokens`, `cache_creation_12h_tokens`, `text_input_tokens`, `image_input_tokens`, `audio_input_tokens`, `video_input_tokens`, `file_input_tokens`, `cached_text_tokens`, `cached_image_tokens`, `cached_audio_tokens`, `text_output_tokens`, `image_output_tokens`, `audio_output_tokens`, `accepted_prediction_tokens`, `rejected_prediction_tokens`. Retain unknown data without making the monitoring UI depend on it.

Aggregate requests by counting records, failures from `failed`, and group by `model`/`provider` and `api_key` for the observing client's own ledger. Avoid double-counting reasoning and cached tokens as independent additions to `total_tokens`; use server-provided accounting totals. `api_key`, IPs, headers, and provider error bodies are sensitive. A native MVP should prefer counters and clearly mark historical token totals unavailable unless a durable collector owns this destructive queue. The current registered stock observability routes are the API-key counter map and this queue; do not assume an old `/management/usage` export contract matches them.

Sources: routes `upstream: internal/api/server_management_v8.go:41-42`, `upstream: internal/api/server_management.go:100-101`; pop/encoding `upstream: internal/api/handlers/management/usage.go:14-63`; generated event and token tags `upstream: internal/redisqueue/plugin.go:211-310`; accounting tags `upstream: sdk/cliproxy/usage/accounting.go:27-48`; retention `upstream: config.example.yaml:1299-1306`.

For the fleet fork's durable inbound-client-key/per-model report, see section 9. It is separate from stock upstream API-key counters and the consuming queue.

## 7. Logs, inbound API keys, routing, and models

### Log tail

`GET /v8/management/observability/logs`

Legacy: `GET /v0/management/logs`.

Query parameters: `limit` (positive integer; omitted means 0/unbounded), `after` (Unix timestamp cutoff), `cursor` (opaque string returned by prior response). Start with `limit=200`; use returned cursor for subsequent pulls. With no cutoff and a positive limit, the handler tails the newest lines. Cursor resets can return a fresh tail.

Response shape:

```text
{
  "lines":[string],
  "line-count":integer,
  "latest-timestamp":int64,
  "next-cursor":string,
  "cursor-reset":true?
}
```

Exact hyphenated keys matter. `cursor-reset` is omitted unless true. `line-count` is not necessarily the length of `lines` on the accumulator path with a limiting filter; it is the server's count. **Captured** with logging-to-file false: HTTP 400 `{"error":"logging to file disabled"}`. This is a configured feature being off, not invalid credentials. Avoid polling without an explicit limit or exposing log text in debug telemetry.

Sources: routes `upstream: internal/api/server_management_v8.go:36-40`, legacy `upstream: internal/api/server_management.go:114`; query behavior `upstream: internal/api/handlers/management/logs.go:40-131`; response `:631-644`; limit validation `:1299-1312`.

Related on-demand endpoints: `GET /v8/management/observability/logs/errors` returns `{"files":[{"name":string,"size":int64,"modified":int64}]}` with Unix modification time; `GET .../logs/errors/:name` downloads an error-log file, and `GET .../logs/requests/:id` downloads the request log. File downloads are not JSON monitoring snapshots. Sources: `upstream: internal/api/handlers/management/logs.go:197-259,261,430`; routes `upstream: internal/api/server_management_v8.go:38-40`.

### List inbound client API keys

`GET /v8/management/config/access/api-keys`: raw config array; **captured** `[]`.

`GET /v0/management/api-keys`: `{"api-keys":[string]}`; **captured** `{"api-keys":[]}`.

Stock entries are configured inbound access keys. Fleet can use policy objects in the raw config array, so do not force every fleet entry to a string. Prefer fleet `/client-key-policies` for safe metadata without raw secrets. Management API-key listing is not available to an ordinary client key.

Sources: generic v8 config `upstream: internal/api/server_management_v8.go:25-26`, `upstream: internal/api/handlers/management/config_v8.go:50-85`; legacy `upstream: internal/api/server_management.go:95`; `upstream: internal/api/handlers/management/config_lists.go:158`; fleet policy parsing `fleet fork: internal/api/handlers/management/client_key_policies.go:69-95`.

### Routing strategy read/update

| Contract | Read | Update body | Success |
| --- | --- | --- | --- |
| v8 | `GET /v8/management/config/routing/strategy` → raw JSON string, e.g. `"round-robin"` | `PUT /v8/management/config/routing/strategy` with JSON **string** `"fill-first"` | `{"config-version":8,"status":"ok"}` |
| v8 object patch | `GET /v8/management/config/routing` → object | `PATCH /v8/management/config` with `{"routing":{"strategy":"fill-first"}}` | Same v8 success |
| v0 | `GET /v0/management/routing/strategy` → `{"strategy":"round-robin"}` | `PUT` or `PATCH` same v0 path with `{"value":"fill-first"}` | `{"status":"ok"}` |

The v8 leaf PUT and read-back were executed on the temporary binary: response `{"config-version":8,"status":"ok"}`, followed by `"fill-first"`; the v0 read then returned `{"strategy":"fill-first"}`. Use `If-Match` with v8 writes to detect concurrent changes. Accepted canonical values: `round-robin`, `weighted-round-robin`, `fill-first` in current stock. Do not infer older-fork support from a newer-stock version. V0 validation returns 400 for invalid body/strategy.

Sources: v8 generic routes `upstream: internal/api/server_management_v8.go:20-27`; config write/merge `upstream: internal/api/handlers/management/config_v8.go:88-213,360`; legacy route `upstream: internal/api/server_management.go:131-133`; legacy handler `upstream: internal/api/handlers/management/config_basic.go:312-352`; v8 strategy declaration `upstream: config.example.yaml:177-179`; panel v8 read/patch `panel: src/services/api/routing.ts:114-127,303-323,422-424`.

### Client-visible model list

`GET /v1/models` with an **inbound client key**, ordinarily `Authorization: Bearer <client-key>`. A management key is not a substitute. `X-Api-Key`, `X-Goog-Api-Key`, `key` and `auth_token` query parameters are also accepted by stock's configured access provider, but do not put keys in URLs in a native client.

For the OpenAI shape, use the app's own ordinary User-Agent and omit `Anthropic-Version` and the `client_version` query. An Anthropic-Version header or `claude-cli` User-Agent selects an Anthropic response shape; specialized CLI/User-Agent and Home paths have other behavior.

```text
{"object":"list","data":[{"id":string,"object":"model","created":int64?,"owned_by":string?}]}
```

**Captured:** `{"data":[],"object":"list"}`. The capture server had no configured client keys, so standard proxy auth was permissive; a production server with configured keys requires one. Authentication failures return 401; policy failures can be 403. The list is from the local registry, not a direct provider `/models` fetch; empty list is valid and does not prove auth failure. Fleet filters model visibility through client policy. Model listing does not prove each listed model can currently complete inference.

Sources: stock route `upstream: internal/api/server_routes.go:65-73`; response filtering `upstream: sdk/api/handlers/openai/openai_handlers.go:65-110`; format switch `upstream: internal/api/server_routes.go:625-668`; accepted keys `upstream: internal/access/config_access/provider.go:55-110`; auth middleware `upstream: internal/api/server_middleware.go:502-558`; fleet policy-visible models `fleet fork: internal/api/server_fleet_limits.go:175-188`.

## 8. Client-key-only fleet quota mode

### `GET /v1/fleet/limits`

Use `Authorization: Bearer <client-key>`; **no management key is needed**. This is a **fleet fork extension**, not stock 8.0.69. The local stock binary returned **HTTP 404**. Feature-detect once per server connection/version; present model-list-only mode when absent. A 401 means authentication failed, not absent feature; 403 means access/policy rejection. A reverse proxy can also produce 404, so report feature unavailable rather than asserting the server implementation from status alone. No body is required.

Fleet requires an authenticated `userApiKey` principal even when ordinary proxy auth would otherwise allow anonymous use. Response sets `Cache-Control: no-store`. It reads locally held auth/model/quota observations; the handler does not request provider quota or spend inference tokens.

**Complete wire schema** (all keys required unless explicitly optional):

```text
{
  "object":"fleet.limits",
  "generated_at":string,
  "proxy_version":string,
  "client":{"name":string|null},
  "models":[{"id":string,"providers":[string]}],
  "exclusions":[{
    "pattern":string,
    "provider":string|null,
    "source":string,
    "until":string|null,
    "until_source":string|null
  }],
  "credentials":[{
    "label":string,
    "provider":string,
    "plan":string|null,
    "state":string,
    "bars":[{
      "id":string,
      "percent":number|null,
      "status":string|null,
      "resets_at":string|null,
      "sampled_at":string|null,
      "reset_passed":boolean
    }],
    "credits":{"has_credits":boolean|null,"unlimited":boolean|null,"balance":number|null},
    "cooldowns":[{
      "scope":string,
      "model":string|null,
      "reason":string,
      "until":string,
      "http_status":integer|null
    }]
  }],
  "summary":{
    "<provider>":{
      "usable_credentials":integer,
      "bars":{"<bar-id>":{"percent":number,"resets_at":string|null}}
    }
  }
}
```

`credits` is **optional**, emitted for Codex credentials (including all-null unknown credit data), omitted for other providers. Every other nullable field shown above is emitted as null rather than omitted. Empty collections are arrays/maps, not absent values. Credential labels are server-generated opaque privacy-preserving labels; they are **not email addresses, auth filenames, or management auth_index values**, and cannot be used to mutate management accounts.

Semantics important for quota UI:

- `percent` is **used percent**. Null means unknown, never zero. Fleet rounds to one decimal; it does not clamp the number to 0–100.
- Current bar IDs include `weekly_all`, `weekly_fable`, `session_5h`, or `window_<minutes>m` for other Codex windows. IDs are extensible.
- Claude bars come from unified 7d, 7d_oi, and 5h provider headers; raw utilization fractions are multiplied by 100. Codex header used-percent is already percent; window minutes determine the bar ID. The freshest observation carrying each window wins.
- Claude `status` is `allowed`, `allowed_warning`, `rejected`, or null; Codex can have null status despite a known percent.
- `resets_at`, `sampled_at`, `generated_at`, exclusion `until`, and cooldown `until` are UTC RFC3339 or null where typed nullable. `reset_passed` is true when the stored reset time is before the response-generation time. It does **not** overwrite a credential's raw stored percent.
- Credential `state` precedence is `disabled`, then credential-level `cooldown`, then `error`, otherwise `active`. Per-model cooldowns can coexist with state `active`; `cooldowns[].model` (not `model_key`) identifies the model here.
- `summary` is **not average fleet consumption**. For usable credentials it chooses the lowest used percent for each bar ID (best available headroom), with that observation's reset time. Expired resets contribute 0. Disabled or credential-cooldown accounts do not contribute; the implementation's usable count can still include an `error` state without a credential-level cooldown.
- A sampled plan with no 5h bar contributes a synthetic summary `session_5h: {percent:0,resets_at:null}`; missing weekly samples remain unknown/absent. Do not copy that synthetic summary onto each account.
- `exclusions[].source` is `oauth-excluded-models` or `key-policy`; `until_source` can be `config`, `quota_reset`, `cooldown`, or null. A null expiry is not a guessed reset time.
- Visibility is constrained by client-key policy. Do not assume the credential list is the whole server fleet or that a client can learn credential names/emails.

A minimal **source-derived**, empty-view example (not captured from stock):

```json
{
  "object":"fleet.limits",
  "generated_at":"2026-11-14T00:00:00Z",
  "proxy_version":"8.0.42",
  "client":{"name":null},
  "models":[],
  "exclusions":[],
  "credentials":[],
  "summary":{}
}
```

Sources: registration `fleet fork: internal/api/server_routes.go:93`; all JSON tags `fleet fork: internal/api/server_fleet_limits.go:16-86`; authentication/generation/filtering `:91-172`; credential state/bars/credits `:191-243`; summary behavior `:246-276`; normalized quota and IDs `fleet fork: sdk/cliproxy/auth/quota_limits.go:46-203`; exclusion-source constants `:40-44`.

## 9. Optional fleet management extensions

These are **management-mode capabilities**, not powers granted to an ordinary client key by `/v1/fleet/limits`. Discover on the connected fork; do not assume stock support. Routes: `fleet fork: internal/api/server_management_v8.go:21-33,50`. A configured **issuer key** is a separate restricted management principal: it may access issued-key operations and client-key usage, but not general config/account management. See `fleet fork: internal/api/handlers/management/key_issuer_auth.go:16-32`.

### Policy metadata (safe alternative to fetching key secrets)

- `GET /v8/management/client-key-policies` → bare array of `Policy`.
- `GET /v8/management/client-key-policies/:name` → one `Policy`. Name lookup falls back to a zero-based decimal index. Duplicate names return 409 `ambiguous_name`; unknown key returns 404 `not_found`.
- `PUT /v8/management/client-key-policies/:name` replaces the four policy lists with a body containing `models`, `excluded-models`, `credentials`, `excluded-credentials` (arrays of strings).
- `PATCH` the same path accepts `{"add":{<lists>},"remove":{<lists>}}`; absent lists do not add/remove entries. Unknown body fields are rejected.

`Policy` is exactly:

```text
{
  "issued-by":string,"expires-at":string,
  "index":integer,"name":string,"has_policy":boolean,
  "models":[string],"excluded-models":[string],
  "credentials":[string],"excluded-credentials":[string]
}
```

Lists are normalized to empty arrays. These metadata responses do **not** contain the key string. Success on write flattens `{"status":"ok"}` and the Policy fields into one object. Errors use `{"error":string,"message":string}`.

Source: `fleet fork: internal/api/handlers/management/client_key_policies.go:15-47,69-135,194-205,225-226`.

### Issued keys

- `GET /v8/management/issued-keys` → bare array of `IssuedKey`; management sees all issued keys, issuer principal sees only its own.
- `POST /v8/management/issued-keys` body: `{"name":string,"models":[string]?,"ttl":string?,"expires-at":string?}`. Name must match `[A-Za-z0-9._-]{1,64}`. Specify at most one of positive Go-duration `ttl` (e.g. `2h`) and future RFC3339 `expires-at`.
- POST returns **201** with the IssuedKey fields **plus `"key":string`**. This is the one-time secret-returning result: immediately move the key into Keychain, never fixture/log it.
- `DELETE /v8/management/issued-keys/:name` → `{"status":"ok","revoked":integer}`.
- Management-only bulk DELETE `/v8/management/issued-keys?issued-by=<issuer>` → same shape. Key revocation is a user-confirmed destructive action, never a refresh operation.

`IssuedKey` = `{"name":string,"issued-by":string,"created-at":string,"expires-at":string,"models":[string],"excluded-models":[string]}`. No key in GET. Creation timestamp can include fractional seconds. Errors have `error`/`message`; 409 `name_exists` or `last_client_key`, 404 `not_found`, and 400 validation errors are meaningful cases.

Source: `fleet fork: internal/api/handlers/management/key_issuer.go:20-39,42-81,95-151,173-184`.

### Durable per-client-key/per-model usage

`GET /v8/management/usage/client-keys?from=<RFC3339>&to=<RFC3339>&key=<name>`

All query parameters are optional. `to` defaults to now; `from` defaults to recording start when known. The server floors `from` and ceils `to` to whole hours. Bad windows return 400 `{"error":"invalid_window","message":string}`. Response has `Cache-Control: no-store`.

```text
{
  "object":"fleet.client_key_usage",
  "generated_at":string,
  "from":string,"to":string,
  "recording_since":string|null,
  "granularity":"hour",
  "keys":[{
    "name":string,"created_at":string|null,"revoked":boolean,
    "requests":int64,"failed_requests":int64,
    "input_tokens":int64,"output_tokens":int64,"reasoning_tokens":int64,
    "cache_read_tokens":int64,"cache_creation_tokens":int64,"total_tokens":int64,
    "models":[{
      "provider":string,"model":string,
      "requests":int64,"failed_requests":int64,
      "input_tokens":int64,"output_tokens":int64,"reasoning_tokens":int64,
      "cache_read_tokens":int64,"cache_creation_tokens":int64,"total_tokens":int64
    }]
  }]
}
```

Note the underscore `created_at` here versus hyphen `created-at` in issued-key metadata. This report measures **inbound client usage**, unlike stock's upstream API-key counters. It is a report read, not a destructive queue pop. Empty `keys` is valid and a null recording start means no known recording start, not a lifetime zero-consumption guarantee.

Sources: `fleet fork: internal/api/handlers/management/fleet_key_usage.go:13-74,91-124`; counter/model tags `fleet fork: internal/fleetusage/ledger.go:23-32,50-54`; route `fleet fork: internal/api/server_management_v8.go:50`.

## 10. Recommended native-client flow

### Management connection / refresh

1. Connect over HTTPS in real deployments. Store only the connection profile and key reference in ordinary preferences; actual keys belong in Keychain.
2. Probe `GET /v8/management/config` once for v8 capability/auth and read the installed-version/plugin headers. Do not log the body. If a verified older server requires v0, use the explicit legacy route mapping above; do not silently downgrade on a 401/403 or treat every 404 as an old version.
3. On regular refresh, GET `/v8/management/credentials` (paginate larger fleets), and optionally `/v8/management/observability/usage/api-keys` if the UI needs config-backed provider key counters. Get routing only when showing settings or after a change.
4. Poll log tail only while that screen is visible, always bounded, continuing with `next-cursor`. Treat logging-disabled 400 as an off state.
5. Fetch per-account model lists only for details/routing UI. Fetch client-visible `/v1/models` only when the app also has a client key; a management key alone is not client auth.
6. Refresh provider quota on explicit user request or a conservative cached cadence, independently of the cheap account refresh. Limit concurrency, keep old values marked stale on errors, and back off provider 429s. `api-call` and plugin **GET** quota routes can hit providers/refresh OAuth; they are not cheap local counters. Prefer observed signals or fleet limits when available.
7. After status/routing/cooldown writes, re-read the relevant account/config state. For v8 config, use ETag/If-Match and handle 412 by refreshing rather than overwriting concurrent changes.
8. Do not drain the usage queue as a casual dashboard refresh. Use a dedicated collector if historical token totals are a product requirement, or fleet's durable client-key report when available.

### Client-key-only connection / refresh

1. GET `/v1/models` using the client key and OpenAI-compatible request headers.
2. Probe GET `/v1/fleet/limits`. On 200 decode the complete schema above; on 404 show models-only/unsupported-quota mode; on 401/403 fix auth/policy rather than hiding the error.
3. In fleet mode, refresh limits for fresh local observations and update reset countdowns locally between refreshes. Keep `sampled_at` visible: a cheap limits refresh does not force new provider measurements.
4. Do not call management/account-control endpoints in this mode. Do not identify opaque fleet labels as account filenames.

### Cost/side-effect classification

| Operation | Local/provider work | Polling guidance |
| --- | --- | --- |
| Health, config GET, credentials GET, API-key counters, account models, `/v1/models` | Local process/disk/registry state | Cheap; still avoid overly frequent full-fleet reads. |
| Fleet limits | Local stored quota/model/auth state | Cheap; stored samples may be stale. |
| Fleet client-key usage report | Local usage ledger | Read-only report; choose bounded time range. |
| Logs GET | Local files, potentially large reads | Bounded tail while visible. |
| Usage queue GET | Local **destructive pop** | Dedicated consumer, not an ordinary observer. |
| API-call provider usage, plugin quota fetch | Upstream HTTP, possible OAuth refresh, provider rate limits | Cache and throttle; outer HTTP 200 does not imply provider success. |
| Latest-version / model-definition refresh | External release/catalog HTTP | On-demand or infrequent; unrelated to installed-version detection. |
| Cooldown reset, account status, config writes | State-changing; local persistence/reload | Explicit user action, re-read afterward. |
| Plugin quota reset / provider credit consumption | Potential upstream state/credit changes | Separate confirmed action; never automatic recovery. |

This polling advice is a client recommendation, not an upstream mandated refresh interval. Source mechanisms are cited in the endpoint sections; no provider inference was generated to collect this reference.

## Captured fixtures

All files are raw stock responses and contain no configured keys, account emails, auth filenames, provider tokens, or private server configuration:

| File | Request | HTTP | Exact useful evidence |
| --- | --- | --- | --- |
| `fixtures/config-routing.json` | `GET /v8/management/config/routing` | 200 | Raw selected object: `{"strategy":"round-robin"}`. |
| `fixtures/auth-files-empty.json` | `GET /v8/management/credentials` | 200 | `files` array plus fractional RFC3339 `observed_at`. |
| `fixtures/api-key-usage-empty.json` | `GET /v8/management/observability/usage/api-keys` | 200 | Bare empty object `{}`. |
| `fixtures/client-models-empty.json` | `GET /v1/models` | 200 | OpenAI `object:list` and empty `data`. |
| `fixtures/management-key-missing.json` | `GET /v8/management/config/routing` without key | 401 | `{"error":"missing management key"}`. |
| `fixtures/client-api-keys-empty.json` | `GET /v8/management/config/access/api-keys` | 200 | Bare empty array `[]`, not `{"api-keys":[]}`. |

Populated provider quotas, successful account toggles/cooldown resets, and fleet extension responses are source-derived only. The stock binary's 404 for `/v1/fleet/limits` and the routing write/read-back were also probed, but are not extra fixture files.

`fixtures/fleet-limits-cooling-pool.json` is a `GET /v1/fleet/limits` response from a fleet build with anonymised credential labels (no client block, models or generated time). It holds four Claude accounts (one active, one disabled, two in a credential-wide cooldown because their all-model weekly window is at the limit) and one Codex account at its weekly limit. The pooled-capacity tests read it in both client-key and an equivalent management form.
