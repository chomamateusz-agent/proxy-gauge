# Proxy Gauge privacy policy

_Last updated: 14 November 2026_

Proxy Gauge is a monitoring app for CLIProxyAPI servers that you run or have access to. This policy explains what the app does with data.

## Summary

Proxy Gauge does not collect, sell or share any personal data. It has no analytics, no tracking, no advertising, no user accounts and no third-party SDKs. The developers of Proxy Gauge never receive any data from the app.

## Data stored on your device

- **Server list**: the names and addresses of the servers you add, which server is the default, and your refresh setting. These are stored in the app's local settings on your device (shared with the app's own widget through an App Group).
- **Keys**: management keys and client keys are stored only in the iOS or macOS Keychain on your device. They are never stored in settings files, logs or backups made by the app.
- **Last widget values**: the most recent headroom percentages for your default server, so the widget can show them when the server is unreachable.

Deleting a server in the app removes its entry and its key from your device. Deleting the app removes all of the above.

## Network connections

Proxy Gauge connects only to the server addresses you enter. Requests carry the key you saved for that server so the server can authenticate the app. The app does not connect to any other service. The built-in demo server makes no network connections at all.

What the app reads from your server (account names or email labels, quota usage, request counts, model names, server version) is shown on your device and is not sent anywhere else.

## Children

Proxy Gauge is a developer tool and is not directed at children.

## Changes

If this policy changes, the new version will be published at this address with a new date.

## Contact

Questions about this policy: open an issue in the project's GitHub repository.
