# Networking and App Transport Security

Proxy Gauge connects to servers whose addresses the user types in. CLIProxyAPI is usually self-hosted: on the same Mac, on a home server, on a NAS, or on a machine reached over Tailscale. Many of these servers only speak plain HTTP (the default CLIProxyAPI listener is `http://<host>:8317`).

## Info.plist settings

All three bundles (iPhone app, widget extension, Mac app) set only:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key><true/>
</dict>
```

- `NSAllowsArbitraryLoads` is needed because user-entered servers include plain-HTTP fully qualified names: Tailscale MagicDNS names (`your-host.tailnet-name.ts.net`), split-horizon DNS names on a home network, and plain-HTTP reverse proxies. The set of hosts cannot be known at build time, so per-domain exceptions are not possible. It also covers local addresses (`.local` names, unqualified host names and private IP addresses).
- `NSAllowsLocalNetworking` is deliberately **not** set. On iOS 10+ and macOS 10.12+, its presence makes the system ignore `NSAllowsArbitraryLoads`, which would block every plain-HTTP fully qualified host.

The widget extension needs the same keys because it fetches the default server's data itself.

## Mitigations

- The app only ever connects to addresses the user entered. It has no other network destinations.
- An address typed without a scheme gets `https://` for fully qualified names and `http://` only for local hosts (loopback, private and Tailscale IP ranges, `.local`, unqualified names). Addresses with a user name or password are rejected, so nothing but the key in the Keychain is used for authentication.
- The server editor warns when an address uses plain HTTP and the host is not on a private network (loopback, RFC 1918, link-local, CGNAT/Tailscale `100.64.0.0/10`, `.local`, or unqualified names), because the key would travel unencrypted.
- HTTPS is used whenever the user enters an `https://` address; certificate validation is never disabled.

## Local network permission (iOS)

`NSLocalNetworkUsageDescription` explains that the app connects to CLIProxyAPI servers on the local network. iOS shows this prompt the first time the app reaches a LAN address.

## App Review note

Suggested text for the review notes: "Proxy Gauge is a client for self-hosted CLIProxyAPI servers. Users enter their own server address, which is commonly a plain-HTTP address on their LAN or a Tailscale host name, so ATS arbitrary loads are required. The app contacts no other hosts. A built-in Demo server (no network) is available for review."
