# Proxy Gauge

A native iPhone and Mac app for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) servers. See how much quota your Claude, Codex and other accounts have left, which accounts are cooling down, and how much traffic the proxy has served, from your phone.

There are several macOS menu-bar apps for CLIProxyAPI. Proxy Gauge exists because there was nothing for the iPhone; the Mac app comes from the same code.

## Screenshots

Built-in demo server, Mac. A two-column window with the server's sections in the sidebar, the same panel-style provider rows and account cards as on iPhone, and a freshness bar with Reload from API and Refresh from provider on every pane:

<p>
  <img src="docs/screenshots/mac-overview.png" width="420" alt="Overview with the account summary, the provider filter, one row per provider with its percent per window, and the account cards with a fixed row per window below each provider, Mac">
  <img src="docs/screenshots/mac-router-order.png" width="420" alt="Overview of a fork server in router order: each card carries its router position pill, such as 1 Next, and the provider row says which order the cards follow, Mac">
  <img src="docs/screenshots/mac-accounts.png" width="420" alt="Accounts with the account cards grouped by provider, Mac">
  <img src="docs/screenshots/mac-account-detail.png" width="420" alt="Account detail of a cooling-down account with its quota windows, provider facts, cooldowns and requests, Mac">
  <img src="docs/screenshots/mac-settings.png" width="420" alt="Settings pane with the server list, the selected server's facts and auto refresh, Mac">
  <img src="docs/screenshots/mac-overview-dark.png" width="420" alt="Overview in dark mode, Mac">
  <img src="docs/screenshots/mac-cooldown-popover.png" width="220" alt="Status popover of a cooling-down account: when it is back, why, what comes back and which models are paused, Mac">
  <img src="docs/screenshots/mac-resets-sheet.png" width="300" alt="Resets sheet of a cooling-down account with every window and the paused models, Mac">
  <img src="docs/screenshots/mac-menubar.png" width="280" alt="Menu bar with pooled capacity and the account list, Mac">
  <img src="docs/screenshots/widget-pooled-medium.png" width="364" alt="Medium pooled capacity widget">
</p>

Built-in demo server, iPhone. The app opens straight into the default server, with a tab bar and a freshness row with two labelled buttons, Reload from API and Refresh from provider, under every tab:

<p>
  <img src="docs/screenshots/overview-compact-rows.png" width="200" alt="Overview tab with the account summary and one row per provider with its percent per window and how many accounts report it, iPhone">
  <img src="docs/screenshots/provider-detail.png" width="200" alt="Claude provider detail with the provider percent per window, accounts usable now and the usable and blocked share per window, iPhone">
  <img src="docs/screenshots/provider-detail-accounts.png" width="200" alt="Account cards in two columns right after Refresh from provider: the result line, plan and manual resets, a fixed row per window with a dash for a window the account does not report, and the status pill, iPhone">
  <img src="docs/screenshots/cooldown-popover.png" width="200" alt="Status popover of a cooling-down account: when it is back, why, what comes back, manual resets and plan from the last provider check with its age, and which models are paused, iPhone">
  <img src="docs/screenshots/resets-sheet.png" width="200" alt="Resets sheet of one account with every window, what comes back and the manual resets left, iPhone">
  <img src="docs/screenshots/accounts.png" width="200" alt="Accounts tab with account cards grouped by provider and the result line of Refresh from provider, iPhone">
  <img src="docs/screenshots/account-detail.png" width="200" alt="Account detail with the freshness row, quota windows and the plan, iPhone">
  <img src="docs/screenshots/settings.png" width="200" alt="Settings tab with the server list and the selected server's facts, iPhone">
  <img src="docs/screenshots/overview-pl-dark.png" width="200" alt="Overview in Polish, dark mode, iPhone">
</p>

## Status

Internal TestFlight builds; App Store release in preparation. Until then, build it from source (see [Building](#building)).

## Features

- **Several servers**, each with a name, address and either a management key or a client key. The app checks a server when you save it and shows what it found: version, accounts or models, and which optional endpoints answer.
- **iPhone navigation**: the app opens straight into your default server, on its Overview (Limits for a client-key server), with a tab bar: Overview, Accounts, Usage, Models and Settings for a management key, and Limits, Models and Settings for a client key. With more than one server, the title of the first tab (the server name) is a menu: pick another server there, or "Manage servers" to jump to the Settings tab. Switching servers keeps the tab you are on when the other server has it, and otherwise opens its first tab. Servers are managed in the Settings tab: the server list (tap to switch; swipe or touch and hold to edit, make default or delete; "Add server"), then the selected server's facts (version, commit, accounts on the server, server time and the "Refresh automatically" switch), "Server settings" and "Edit server", the Lab section on fleet-fork servers (see below), and "App settings" (auto refresh, limits from providers). Under every tab, and on provider and account pages, a freshness row shows when the data is from (fresh, refreshing, saved, or server not reached) next to two labelled buttons, Reload from API and Refresh from provider (on a second line when both do not fit next to the time); each tab keeps its own time. Adding your first real server while the demo server is selected switches to it. On the Mac the window has two columns: the server's sections in the sidebar (the same as the iPhone tabs) and the selected section next to it. With more than one server, a Servers menu in the toolbar switches servers, adds one or jumps to "Manage servers". The Settings section holds the server list, the selected server's facts, "Server settings", the Lab section and the app settings in one pane; the app settings are also in the app's Settings window. Every pane, Settings included, has a freshness bar with the same two buttons; both are also menu commands (Reload from API ⌘R, Refresh from provider ⇧⌘R).
- **Built-in demo server** with realistic sample data (seven accounts across Claude, Codex, Gemini CLI and xAI in every state, plus simulated provider answers for Refresh from provider), clearly labelled, so you can try the app without a proxy. You can delete it like any other server and bring it back with "Add demo server" when adding a server.
- **Management key mode**
  - Overview, in the style of the CLIProxyAPI management panel: a summary line ("7 accounts · 6 loaded · 1 needs attention") and one row per provider with its numbers per window, read the way the panel reads them (see [The provider percent](#the-provider-percent)). Each window shows the provider percent on a 0 to 100 scale and how many accounts report it ("3 of 3 accounts"); for Claude the percent is weighted by plan when every account's plan is known (Max 20x counts 20, Max 5x counts 5, Pro counts 1). Every provider has fixed windows, so the rows line up the same way on every server: Claude 5-hour, Weekly and Weekly Fable, Codex 5-hour and Weekly (a 28 to 31 day Codex window fills the Weekly slot, which is labelled "Monthly" when all its readings are monthly), xAI Weekly. A provider whose accounts report nothing says why, for example which account needs a new sign-in. On the Mac and other wide windows the account cards follow below each provider, and a provider filter (All, or one provider with its account count) narrows the page. When the server cannot be reached or automatic refresh is off, the Overview shows the provider rows from the last saved data with their age ("Showing data saved 2 hr ago"), unweighted because the saved data has no plans. Server details (version, commit, accounts on the server, server time and the automatic refresh switch) are in Settings, on the Mac together with "How these numbers work".
  - Provider detail: opening a provider row shows the same row with "2 of 3 usable" and status chips (for example "2 active", "1 cooling down"), the share of each window usable now and blocked ("34% usable now · 4% blocked"), which account comes back when and how much it adds, and the provider's account cards.
  - Account cards (provider detail, Accounts and, on wide windows, Overview; the same cards on iPhone and Mac): one card per account, at most two columns on iPhone (one column, at full width, at accessibility text sizes) and an adaptive grid on the Mac. Every card of a provider has the same fixed window rows in the same order, each with the remaining percent, the reset date and time and how long until then; a window the provider did not report shows "–" with an empty track, and a reported 5-hour window with 0% used and no reset time shows 100% with no date. A facts row shows the plan, manual resets left (only when at least one usable grant is left), paid until and extra usage from the latest provider check, with shorter labels when space is tight and a second line only as a last resort. Facts from a check older than the latest account load move to the status popover, with their age ("Checked with the provider 3 min ago"). The status pill (a dot for active, or "Cooling down", "Disabled", "Needs sign-in") opens a popover: when the account is back and why (for example "5-hour limit reached"), what comes back per window, which models are paused until when, "Show all resets" (every window with its reset time and what comes back, the paused models and the manual resets left) and "Refresh from provider" for that account ("Available in 40 s" while it has to wait). When the last check with the provider failed, the card shows it in a red box ("Failed to load quota: HTTP 503.") and the account counts as needing attention. Cards are ordered usable first, or by router position on fleet-fork servers (see Router order below).
  - Accounts: the account cards grouped by provider with the same summary line as the Overview and, on the Mac, the provider filter. Opening an account shows its windows with "Show all resets", the plan when the provider reports one (each bar that came from a provider carries the antenna mark, with a tooltip and a VoiceOver label), the provider facts, the cooldowns, the recent request chart, enable/disable and reset cooldown (each with a confirmation).
  - Usage: request totals, failures, a chart of the last 200 minutes, requests per provider, and token totals per model when the server keeps a client-key usage report.
  - Models available across your accounts.
  - Server settings: routing strategy (read and change, protected against concurrent config edits; when the server reports no config version, the app asks once more before an unconditional write), and the number of configured client keys on servers that publish client-key policies. Key values are never read or shown.
  - Router order (Lab, fleet fork only): on management-key servers running the fleet fork, which reports its routing settings with the accounts, Settings shows a Lab section with a "Router order" switch (on by default). Account cards then follow the order in which the proxy picks accounts, like Quota Cards in router order in the fork panel, and each card's pill shows its router position: "1 Next" for the account the next new session goes to, then "2", "3" and so on, with the reason next to the position when there is one ("3 · 5-hour cap", "weekly limit"), or "Not in rotation", "Cooling down", "No reading" and "Ended" for accounts the router skips. The provider row says "Order: use-or-lose estimate for new sessions."; a provider the fork does not rank, such as xAI, shows "List order" like the panel. When the server routes with another strategy (for example fill-first), the cards keep their status pills in list order and the provider row says so once ("Order: list order. Routing uses fill-first."). Until the routing settings have been read, the cards keep the usable-first order. Stock CLIProxyAPI is fully supported: it is never asked for routing settings, shows no Lab section and no router pills, and every other feature, the panel-style provider numbers included, works the same.
- **Two refresh buttons.** **Reload from API** (⌘R on the Mac) reads again what the CLIProxyAPI server already holds; the bar shows "Loading…", then "Reloaded". **Refresh from provider** (management key only, ⇧⌘R on the Mac) asks the providers for fresh limits through the server, the way the panel's "Refresh quota" and "Refresh all credentials" do, for the accounts in view: all accounts on Overview and Accounts, the provider's accounts on a provider page, one account on an account page or in a card's status popover. It starts at once: the pressed button shows a spinner, both buttons stay disabled, and the bar shows a progress line ("Checking 2 of 5 accounts…"). When it ends, the cards change together with a result line that stays about five seconds ("Checked 5 accounts · 0 failed"); tap it to see which accounts failed and why. While every account in view still has to wait (see the throttling rules below), the button is disabled and says "Available in 40 s". Requests that need your approval, Antigravity's unofficial Google endpoints and the xAI paid-key check, are not sent by the button: the result offers "Review checks that need approval", a sheet that lists what will be contacted and sends nothing until you confirm. The results add the plan, manual resets left and when they expire, extra usage and credits to cards and the account page, and every bar that came from a provider carries a small antenna mark. An optional setting refreshes them automatically while the app is visible. See [Refreshing limits from providers](#refreshing-limits-from-providers).
- **Client key mode**: the models the key may call, pooled capacity per provider and the credentials as account cards grouped by provider, with exclusions; the Resets sheet lists each paused model with its own end time, on servers that offer `/v1/fleet/limits`. Stock CLIProxyAPI does not have that endpoint; the app says so plainly.
- **Remaining quota everywhere**: every bar (per account, pooled, headroom, widget, menu bar) shows how much is left and fills with the remaining share, coloured by it (red when little is left), like the CLIProxyAPI web panel.
- **Pull to refresh** and auto refresh of the visible screen while the app is open (default 60 s, configurable). Automatic refresh is a switch per server in Settings ("Refresh automatically", on by default). With it off, nothing refreshes that server on its own: not at launch, not when the app comes back to the foreground, not on the first visit of a section, not when an account is opened and not after a failed load. The Overview (Limits in client-key mode) and the menu bar show the last saved pooled capacity and best account, recomputed for the current time, with their age and the hint "Automatic refresh is off — pull to refresh or choose Reload from API."; other screens show the hint. Refreshing by hand (pull to refresh, Reload from API or ⌘R) always works. The switch is enforced in one place, the session's admission check, so every automatic trigger obeys it. Pulling to refresh an account always reloads the account, even while the page is still loading its models, and loads its models only when they are not loaded yet or automatic refresh is on. When the server rejects the key, automatic refresh (app, menu bar and widget) pauses until you refresh by hand, a change to the server succeeds, or you save the server again ("Save anyway" after a rejected check keeps the pause on), so a wrong key never runs into the proxy's ban on repeated failed logins. The app sends at most one management request at a time per server entry: refreshes, changes and provider checks wait for each other in one queue, and each request checks the pause right before it leaves. When the server rejects the key, the pause is recorded the moment that answer arrives, before the next queued request gets its turn, so a rejected key costs one failed attempt and nothing else is sent until you refresh by hand or change something. A change you make while a refresh is still running is not sent if that refresh finds the key rejected; the app asks you to refresh first. When the proxy has already banned this network address (for example after failed logins from another client), the app and the menu bar say so and show when the ban ends, and neither they nor the widget blame the key.
- **iPhone widgets**, both opening the app on that server's Overview (Limits for a client-key server) when tapped (`proxygauge://server/<id>/overview`, from a cold launch or while the app is running):
  - **Headroom** (small, medium): the best single account per provider on your default server, lowest first.
  - **Pooled capacity** (small, medium, large, and the lock screen's rectangular and circular): all accounts of a provider added up, so three Claude accounts show for example "187% of 300%". Small shows the binding window of one provider (the window with the smallest share usable now, the plain sum breaking ties), medium shows 5-hour and weekly for each provider with the account count and when capacity grows next, large shows every window. The lock-screen gauges fill to the part usable now, matching their text. Edit the widget to pick the server (the default server unless you choose one) and the primary provider (the one with the least usable now unless you choose one).
- **Mac**: a two-column window plus a menu bar item with pooled capacity, what is usable now and the best usable account per provider, followed by a compact list of that provider's accounts (label, state, each window's remaining percent and reset time); the list scrolls when it gets tall. Without fresh data the menu bar recomputes both from the last saved accounts at the current time, so a reset that passed since then shows up without a request.
- English and Polish.

### What "headroom" (best account) means

CLIProxyAPI records the rate-limit headers that providers send back with normal responses. Proxy Gauge turns those passive observations into quota bars. For each provider it looks at every account that can currently serve requests (not disabled and not blocked: not cooling down, no account-wide window at the limit, not waiting for a new sign-in; an account in the error state still counts when it does not need one), takes that account's tightest window (the window with the least left, where a window at the limit counts as 0%), and shows the best of those as the provider's headroom: how much the best single account can still do. Windows of different accounts are never mixed, so accounts with (90% left in 5-hour, 10% weekly) and (10% 5-hour, 90% weekly) give 10%, not 90%. The app shows it as the "Best usable account" line in the provider tiles of client-key mode and in the menu bar when at least two accounts can take requests (with one it would repeat the pooled numbers); the Headroom widget lists it per provider. Missing data is shown as unknown, never as zero. Pooled capacity (below) adds the accounts up instead, so the two answer different questions: "can one more long session fit on one account?" and "how much is left in total?".

### What is left in a window

Every bar, pooled sum, headroom, widget and menu bar uses one rule for what is left in a window:

1. no usage value and no limit status: unknown, never 100% and never 0%, also after its reset time (a date alone is not a reading);
2. the window's reset time has passed: 100% (the provider starts a fresh window, like the proxy's `reset_passed`);
3. the window is at the limit (a `rejected` status or 100% used): 0%, even when no usage value was reported;
4. otherwise 100% minus the reported usage.

### Five-hour window states

Claude and Codex accounts can have a 5-hour window. Proxy Gauge tells these cases apart:

- **Never sampled**: the proxy holds no quota observation for the account. The card says "No quota data reported yet" and pooled capacity lists it under "Accounts without data".
- **Not reported**: the account reports other windows (for example weekly) but no 5-hour window, or a 5-hour window without a usage value. Like the panel, the card shows its 5-hour row as "–" with an empty track, and nothing is invented for it: the provider percent, pooled capacity and the resets sheet leave the account out of the 5-hour window ("No 5-hour reading, left out: 1"), and the menu bar's account list shows only the windows the account reported. The account still counts in its other windows.
- **Unused**: the provider reported the 5-hour window with 0% used and no reset time. That is real data: the card shows 100% with no date line, and pooled capacity counts the window as full ("1 account reported an unused 5-hour window"; the menu bar and the large widget say "incl. 1 idle account at 100%", the medium widget "+1 idle").
- **Running**: a normal 5-hour window with usage and a reset time.

These states apply only to Claude and Codex. Other providers that happen to report a 5-hour window (for example a Kimi limit of 300 minutes) are counted like any other window: an account without it is unknown, not "No 5-hour window".

### The provider percent

The Overview and provider detail show each provider the way the CLIProxyAPI management panel does: one percent per window on a 0 to 100 scale, the average of what the provider's accounts have left in that window.

- It covers accounts that are enabled, have not ended and report that window; the caption says how many of the provider's accounts that is ("2 of 3 accounts"). An account without a reading for the window is left out rather than counted as 0% or 100%.
- For Claude, when every included account's plan is known, the average is weighted by plan: Max 20x counts 20, Max 5x counts 5, Pro counts 1. Otherwise every account counts the same.
- A window whose reset time has passed counts as full, by the rule above, until a new sample arrives.
- Percents round half up, so 62.5% reads 63%.
- The usable and blocked shares in provider detail ("34% usable now · 4% blocked") split the same window by whether the account can take requests right now. They are not weighted, so with weighting on they can differ from the weighted headline.

The menu bar, the widgets and the Limits page of a client key use pooled capacity instead, described next.

### What "pooled capacity" means

Pooled capacity adds the accounts of a provider together, per window (5-hour, weekly, and the weekly model window where the provider reports one, named after its model, for example "Weekly Fable"). Every account that is not disabled adds 100% of capacity, so three accounts make 300%; a disabled account is left out entirely. The headline is the sum of each account's remaining quota in that window, exactly as the CLIProxyAPI management panel would add up its cards, for example "168% of 300%", with these rules:

- a window at the limit (used 100% or a `rejected` status, with or without a usage value) adds 0% until it resets;
- an account whose window reset time has passed adds 100%, because the provider starts a fresh window (the same rule as the proxy's `reset_passed`); an explicit 0% used with no reset time also adds 100% (the window starts on use);
- an account with no sample for that window is counted as unknown and shown separately, never as 0% or 100%;
- a Claude or Codex account without a reported 5-hour reading is left out of the 5-hour window, both what is left and the capacity (see above).

Part of that sum may not be usable right now. An account is **blocked** while it is in cooldown, while one of its account-wide windows (5-hour, weekly, daily, monthly) is at the limit, or while it waits for a new sign-in; a model window such as Weekly Fable at its limit does not block the account's other windows. A blocked account's remaining quota stays in the headline but is drawn hatched in the bar, and the row adds a line such as "Usable now: 66% · 102% blocked (weekly limit) · 58% back Fri 12:00": how much of the blocked quota comes back first and when. When every blocked account comes back at the same time the line ends in "· back Fri 12:00"; for a sign-in or a cooldown without an end time there is no time, and the account's own row says "Cooldown" without "until". Times use the device's clock format. Without blocked quota there is no extra line. The colour of the row follows the share usable now. Widgets show the short form "Usable now: 66%".

With the anonymised sample in `docs/fixtures/fleet-limits-cooling-pool.json` (one usable Claude account without a 5-hour window, one blocked by its weekly limit with a 5-hour window, one blocked without a 5-hour window, one disabled) the Claude 5-hour row reads "100% of 100%", usable 0%, "100% blocked (weekly limit) · back Fri 12:00": only the account that reported its 5-hour window counts in it.

Each provider shows "Accounts: 3 · usable: 2": all accounts of the provider, and those that can take requests right now (not disabled and not blocked). The provider detail ("2 of 3 usable"), the menu bar and the widget use the same two numbers.

Each window also shows the soonest time the pool grows or more of it becomes usable (the next reset or cooldown end among its accounts). The same numbers appear on the Limits page in client-key mode, in the widget and in the Mac menu bar, computed from the account list in management mode and from the credentials in `/v1/fleet/limits` in client-key mode. The widget recomputes them at display time, so a reset that passes between refreshes shows up without a new request.

### Widget refresh and rate limits

The widgets are built so they cannot add load to the proxy or to the providers:

- **No provider requests.** The widget never asks providers anything. Its numbers are the rate-limit headers the proxy already observed on normal traffic, merged with the limits the app last checked with providers (stored in the App Group next to the snapshot).
- **One request per refresh at most.** A widget refresh sends a single `GET /v8/management/credentials` in management mode, or a single `GET /v1/fleet/limits` in client-key mode, and nothing else.
- **At most every 15 minutes.** Each timeline asks WidgetKit for the next refresh 15 minutes later. iOS treats this as a lower bound and may refresh less often to save battery and its daily widget budget.
- **Shared cache.** The last result per server lives in the App Group with the time its data was loaded. The app writes it when the data changes (a new account list, or new limits from providers), never on a tick that loaded nothing, and keeps the load time rather than the time of writing. New limits from providers are added to the newest saved result, which keeps its own load time, so they are never dropped because the widget saved newer account data in the meantime; the widget in turn adds the stored provider limits after its own request. A widget reuses it instead of fetching while it is younger than 15 minutes. Both widget kinds and every size share that cache and one in-flight request, so placing several widgets does not multiply requests. A failed attempt also waits 15 minutes before the next one.
- **Auth pause.** After a rejected key or an IP ban the widget stops fetching (the same latch as the app and menu bar) and shows the last values with a note until you fix it in the app.
- **Automatic refresh off.** When "Refresh automatically" is off for the server, the widget never fetches; it shows the values the app saved last with "Saved … ago".
- **Freshness.** When the data is older than 15 minutes the widget says "Sampled … ago".

The policy lives in `ProxyGaugeCore` (`WidgetRefreshPolicy`, `WidgetSnapshotRefresher`) with unit tests that count the requests a stub server receives.

Normal refresh (pull to refresh, the Refresh button, automatic refresh, the widget and the menu bar) reads only state the proxy already holds, so it does not spend tokens or provider rate limits. Asking the providers is a separate action, described next. Proxy Gauge never calls plugin quota fetches or endpoints that consume data (the usage queue).

### Refreshing limits from providers

**Passive data** is what the proxy already knows: the rate-limit headers providers send back with normal traffic, and (on the fleet fork) the samples its own background sampler takes. Reading it never contacts a provider. **Active data** comes from asking the provider directly. Proxy Gauge does that only through the management API: it sends `POST /v8/management/requests/api-call` with the account's `authIndex` and the same method, URL, headers and body the CLIProxyAPI management panel uses, and the proxy puts the account's own token in place of `$TOKEN$`. Client keys cannot use this endpoint, so the app offers Refresh from provider only for servers added with a management key and says so in client-key mode.

The proxy answers HTTP 200 even when the provider refused: the provider's status and headers are nested in the body. Proxy Gauge reads them there, treats a nested 429, 5xx, 401 or 403 as a failure and takes `Retry-After` from the nested headers. The proxy does not store these answers, so the app keeps them per proxy address in the App Group, where the widgets and the menu bar find them. For every window the newer reading wins, whether it came from the proxy or from the provider.

How readings are kept:

- **Sample time.** Every window is stamped with the moment its answer arrived, and a relative reset ("resets in 60 seconds") counts from that moment, not from when the refresh was queued.
- **Reported windows stay.** A window the provider reports without a usage value keeps its reset time and status, and the remaining-quota rule above decides what it shows (unknown, 0% at the limit, 100% after the reset). Claude's weekly model window is recognised by its kind and model, with or without a usage value.
- **Account blocks.** When a Codex answer says `limit_reached` or `allowed: false`, only the windows it reports at 100% or more count as at the limit; the other windows keep their own usage and reset time. When no window of that answer is full, the windows keep their values and the account gets the note "The provider reported this account as blocked although no window was full." until a later answer drops the flag.
- **Empty is not missing.** A field the answer reports as empty or zero replaces the last reading (credits that ran out, no reset credits left), and so does a field left out of a successful answer from the endpoint that reports it; a request that failed or was not sent keeps the last reading with its own check time. Provider facts (plan, manual resets, paid until, extra usage) from a check older than the latest account load are shown only in the status popover and the account page, with their age.
- **Partial runs.** Readings already received are kept when a later request of the same account's refresh fails, is rate-limited or is stopped.
- **Manual resets.** Like the panel's "Resets remaining", only grants usable now count: started, not expired and not paused. Expired, not-yet-started and paused grants are left out, and a card shows "Resets" only when at least one usable grant is left. Codex reset credits count when they are available and not expired. When the endpoint that reports the grants answers without a reset block, the old count is cleared; when that endpoint was not read or failed, the old count keeps its own check time, so it leaves the card once the accounts are loaded again.
- **Plans.** The plan counts as checked for the day only when the profile request answered.
- **Identity.** Waits, backoff and readings are kept per account (its auth file, which survives a changed `auth_index`) and per proxy address, so two server entries for the same proxy, or a server deleted and added again, share them. A check already running for an account is shared too: when a second entry for the same proxy asks for it, nothing new is sent and both entries get the result. If that check never reached the provider (the proxy refused the first entry's management key, or the first entry's refresh stopped before sending), the second entry runs the check again with its own key. Each account's readings are saved as soon as its own check finishes, not after the rest of the batch, for every entry that asked for it, each checked against its own edits. Every other entry for the same proxy reads the stored readings again when it loads accounts, before it saves its overview for the widget, and when its server is shown. When a refresh finishes, the overview is saved for the widget whenever the readings differ from the ones this entry last sent to the widget, even if they were already shown on screen. Renaming a server, or saving it again with the same address and key (including "Save anyway"), keeps its readings and its saved overview. Changing the address or key, or deleting the server, removes the readings unless another entry uses the same proxy; the waits stay. A result that arrives after its server was deleted or edited is not saved for that entry. One unreadable stored reading does not drop the others.
- **No reading yet.** When an account has a wait but no reading (for example after deleting and re-adding its server), a manual refresh may still check it once if nothing was sent for it in the last 5 minutes and the provider has not rate-limited it.

What a manual refresh sends per account (normal successful path, not counting token refreshes the proxy may do on its own):

| Provider | Requests | Notes |
| --- | --- | --- |
| Claude | `GET api.anthropic.com/api/oauth/usage`, `GET …/api/oauth/profile` (plan), `GET …/api/oauth/usage?cedar_ember=1&skip_spend=1` (manual reset grants, two seconds later) | 3 requests; grants are read only on a manual refresh |
| Codex | `GET chatgpt.com/backend-api/wham/usage`, `GET …/subscriptions?account_id=…` (when the account id is known), `GET …/wham/rate-limit-reset-credits` | 2–3 requests; plan, credits and reset credits |
| Antigravity | `POST …/v1internal:retrieveUserQuotaSummary` (daily, sandbox, then production host; the next host only after a 404 or an empty answer), `POST daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` (plan) | 2–4 requests; needs the account's Google Cloud project from the account list |
| Kimi | `GET api.kimi.com/coding/v1/usages`, `GET …/coding/v1/me` (plan) | 2 requests; `api.kimi.ai` when the account is a `kimi-ai` account |
| Devin | `POST server.codeium.com/…/SeatManagementService/GetUserStatus` | 1 request; daily and weekly quota and plan |
| xAI | `GET cli-chat-proxy.grok.com/v1/billing?format=credits`, `GET …/v1/billing`, `GET …/v1/user?include=subscription`, `GET …/v1/settings` | 4 requests; when billing reports nothing, the panel's paid-key check adds `GET api.x.ai/v1/me` and **`POST api.x.ai/v1/chat/completions` with `max_tokens: 1`**, a real completion that can cost a token on a paid key (6 requests) |

Gemini CLI has no quota reader in the panel, so the app does not contact it. Meta (key acquisition) and plugin quota fetches are not part of Refresh limits.

Throttling rules, unit-tested against a stub transport that counts requests:

- **One at a time.** One check in flight per account, at most one request in flight per provider across the whole app (including the Mac menu bar), and at most one `api-call` in flight per proxy across all providers. Within a server entry, provider checks also wait for normal refreshes and changes, so only one management request of any kind is in flight. The first request of a batch goes alone. Every request checks again, after its turn, that the batch has not failed, the server is not paused, no rejection was recorded since the refresh started, the refresh was not cancelled and, for automatic refresh, that it is still allowed (switches on, app visible, server still selected). Then its attempt is recorded and the same conditions are checked once more, with nothing in between that check and the start of the transport; if they no longer hold, the recorded attempt is removed and nothing is sent. If the server rejects the management key, the auth pause is recorded the moment the answer arrives, before the next queued request of any kind gets its turn, so nothing else is sent (one failed attempt, then pause). A request stopped before it leaves (by that check, or because its server entry was edited or deleted) is not counted as an attempt and leaves no wait. When the proxy rejects the management key (401, a 403 other than "remote management disabled", or an IP ban) on the first request of an account's check, the provider was not contacted, so that account keeps the wait state it had before. A provider answer that arrives after a newer rejection never clears that pause.
- **Persistent allowance.** Each account's next allowed time lives in the App Group, so relaunching, switching screens or pressing the button again does not reset it. Waits count from the moment a request actually leaves for the proxy (after its turn in the queue) and from when its answer arrived, not from when it was queued, and saved times are rounded up to the next second. A request cancelled after it left keeps its wait, because it may have reached the provider. After a refresh the same account can be refreshed by hand again after 5 minutes. Random jitter of 0–20% is added on top of every minimum, never subtracted. If a saved entry cannot be read, that account is treated as just checked. No saved wait reaches more than 7 days ahead; a longer one saved by an earlier version is shortened once and stored, so its end does not move later on each read.
- **Rate limits.** A nested 429 keeps the last good data and shows "Rate limited by provider, next try at …". The wait is the larger of `Retry-After` (seconds or an HTTP date; 0, past or missing counts as no guidance) and the policy backoff: 30 minutes for Claude, 15 minutes for others, doubling with each consecutive 429 up to 6 hours. A `Retry-After` longer than 6 hours is honoured up to 7 days; a value more than a year ahead is treated as malformed, and the policy backoff applies. After three consecutive 429s automatic refresh stops for that account with a visible note until a successful refresh by hand. Manual refresh respects the same wait and shows when it is allowed again.
- **Rejections.** A nested 401 or 403 stops automatic refresh for that account until you refresh it by hand.
- **Proxy refusals.** Only a refusal that applies to the whole proxy stops the batch: "remote management disabled", a 404 (the route is missing) or a 429 from the proxy itself. After that first refusal no further accounts are sent, and the refused account keeps its attempt and wait. Automatic provider checks for that proxy address then pause for 15 minutes, doubling with each consecutive refusal up to 6 hours. The pause is stored per proxy address in the App Group; an end further than 6 hours ahead (for example, saved while the clock was wrong) is shortened once and stored, so it does not move as time passes. Every automatic check looks at the pause again right before it is sent, so a check that was waiting behind another batch when that batch was refused is not sent. The app shows the error and "The proxy refused provider checks, next automatic try at …" while automatic refresh and automatic provider refresh are both on, "automatic checks are paused until …" while automatic provider refresh is on but automatic refresh is off, and no pause notice while automatic provider refresh is off. A manual refresh ignores this pause and tries again, also when it joined an automatic check that the pause stopped before sending; any `api-call` the proxy answers successfully, whatever the provider returned, ends it. An HTTP 400 from the proxy concerns one account (for example "auth token refresh failed", "auth credential not found for auth_index" or "auth token not found"): only that account fails, its card says why (for example "The proxy could not refresh this account's sign-in.", shown next to an earlier provider rejection if there is one), the rest of the batch goes on and nothing pauses.
- **Never** retries through another route, redeems manual resets or spends reset credits. The only request that can cost anything is the xAI paid-key completion above, and it runs only after you approve it in the approval sheet and both billing endpoints answered successfully without usage, never after a billing error.

**Automatic** ("Refresh limits from providers automatically" in Settings, per server, off by default, every 15, 30 or 60 minutes, default 30) runs only while the app is visible and automatic refresh is on for that server: on the Mac while Proxy Gauge is the active app or its window is not fully covered, minimised or hidden; on iPhone and iPad while it is in the foreground. Never from the widget, the menu bar or the background. Turning the switch off, hiding the window or choosing another server stops a refresh that is already running before its next request. It covers Claude, Codex, Kimi and Devin, never xAI (no completion probes) or the Google adapters, reads Claude at most every 30 minutes, reads plans at most once a day, and never reads reset grants or reset credits.

The demo server simulates all of this without any network traffic, including an xAI account so the paid-check warning shows.

**Risks.** These are private provider endpoints without a published polling allowance, so the intervals above are conservative choices, not guarantees:

- The panel's maintainers declined automatic all-account refresh in [panel PR #384](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/pull/384) (August 2026) because unbounded parallel quota requests every five minutes can trigger upstream 429s; they asked for bounded concurrency and backoff first. Proxy Gauge's one-request-per-provider lane and backoff follow that advice.
- Claude's usage endpoint is known to answer persistent 429s: [claude-code #30930](https://github.com/anthropics/claude-code/issues/30930) (429 with `Retry-After: 0` while the token still worked for normal requests), [#31637](https://github.com/anthropics/claude-code/issues/31637) (polling every 30–60 seconds, and a later report of 10-minute polling, ending in lasting 429s) and [panel #494](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/issues/494) (the reset-grant read right after a usage read got 429). Hence the 30-minute floor and the long backoff for Claude.
- Antigravity uses unofficial Google endpoints and Google's terms restrict access by third-party tools; the approval sheet says so, Refresh from provider never sends them without that approval, and automatic refresh never touches them.
- The fleet fork already samples Claude and Codex usage on its own every few minutes. Proxy Gauge cannot coordinate with that sampler, with the panel in a browser, or with another device, so its intervals are not the account's total polling.

## Setting up your server

### Management key (full access)

Proxy Gauge uses the v8 management API. In the CLIProxyAPI `config.yaml`:

```yaml
management:
  allow-remote: true          # needed when the app is not on the same machine as the proxy
  secret-key: "a-long-random-secret"
```

Restart the proxy. The plaintext secret is hashed on startup. In the app, add a server with the proxy's address (for example `http://192.168.1.10:8317`, or an HTTPS URL with any path prefix your reverse proxy uses) and paste the same secret as the management key.

If the app reports "remote management is disabled", `allow-remote` is still `false`. After five wrong keys the proxy bans the client's IP for 30 minutes; Proxy Gauge stops automatic refresh after the first rejected key for that reason.

### Client key (read-only)

Any key from `access.api-keys` works as a client key. It shows the models that key can use. On servers that provide `GET /v1/fleet/limits` (for example the fleet fork), it also shows per-credential quota bars without needing the management key. A client key cannot change anything on the server.

### Plain HTTP, LAN and Tailscale

Plain HTTP works for local network addresses and Tailscale. The app warns you when it would send a key over plain HTTP outside a private network. See [docs/networking.md](docs/networking.md) for why the app allows HTTP connections.

## Privacy

- Keys are stored only in the Keychain on your device. They are never written to settings files, logs or analytics.
- The app talks only to the servers you add. There are no analytics, no tracking, no accounts and no third-party SDKs.
- See [docs/privacy.md](docs/privacy.md).

## Building

Requirements: Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [Bun](https://bun.sh).

```sh
make test        # Swift package tests + string catalog check
make generate    # writes Apple/ProxyGauge.xcodeproj (not committed)
make build-ios   # ad-hoc signed iOS Simulator build (Keychain and app group work), then checks extracted strings
make build-mac   # unsigned macOS build, then checks extracted strings
make integration CPA_BIN=/path/to/cli-proxy-api  # runs the client against a throwaway local CLIProxyAPI
make renders RENDER_DIR=/tmp/renders  # renders the Mac window with demo data to PNG offscreen (no Screen Recording permission)
```

The portable logic lives in the Swift package at the repository root:

- `ProxyGaugeCore` (Foundation only): API models and decoding, the HTTP client over an injectable transport, quota and pooled-capacity math, the widget refresh policy, deep links and the demo server.
- `ProxyGaugeStore`: Keychain and App Group storage.
- `ProxyGaugeSession`: the per-server session the app screens observe. Refreshes and changes to the server run one at a time through one queue, so an older response never overwrites newer data or a newer key result.

The app targets live in `Apple/`: `Shared` (app screens for iPhone and Mac), `SharedUI` (views shared with the widget, plus the string catalog), `iOS`, `macOS` and `Widgets`. The app name, bundle identifier, team and URL scheme (`APP_URL_SCHEME`) are set only in `Apple/Config/Identity.xcconfig`.

After changing UI strings, build both apps and run `make strings` to sync `Apple/SharedUI/Localizable.xcstrings`, then add the Polish translations. `make test` fails while any catalog entry lacks English or Polish or is stale. `make build-ios` and `make build-mac` then compare every string the Swift compiler extracted during that build (its `.stringsdata` output, the same input Xcode uses to fill the catalog) with the catalog, and fail on any key that is missing, so a new UI string cannot ship untranslated.

Uploading to TestFlight is never automatic: `make testflight CONFIRM=<bundle id>` requires the bundle identifier from the caller, runs `make test`, `make build-ios` and `make build-mac` first, one after another even under `make -j` (so the extracted-strings check gates every upload) and uploads only the packages built in that run.

The API contract the app relies on is documented in [docs/api.md](docs/api.md), with captured responses in `docs/fixtures`.

## License

MIT, see [LICENSE](LICENSE). Proxy Gauge is an independent project and is not affiliated with CLIProxyAPI or any AI provider.
