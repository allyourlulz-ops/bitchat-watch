# bitchat-watch

An Apple Watch (watchOS 26) client for the [bitchat](https://github.com/permissionlesstech/bitchat)
Bluetooth mesh, plus LoRa radios (Meshtastic, MeshCore), an iPhone companion bridge, a small
local "channel chat" protocol, and a macOS test node that runs on anything from Mojave up.

No internet, no accounts, no servers. Everything is local radio or local network.

> Status: protocol/crypto core is tested on Linux (see [Test results](#tests)). The Apple UI
> and Core Bluetooth / Network / MPC layers have **not been compiled in this repo's own
> environment**; CI on GitHub's macOS runners does that. See [Known unverified items](#known-unverified-items).

## What's in the box

| Path | What it is |
|------|-----------|
| `Shared/BitchatCore` | bitchat wire format, Noise XX, fragments: vendored upstream files (Unlicense) + a leaf mesh engine |
| `Shared/MeshtasticCore` | Meshtastic BLE client protocol; protobuf encoder/decoder hand-written from the `.proto` files |
| `Shared/MeshCoreCore` | MeshCore companion-radio BLE protocol |
| `Shared/ChannelCore` | channel chat v1 (envelope, HKDF keys, router), see [docs/wifi-channel.md](docs/wifi-channel.md) |
| `Shared/Companion` | watch ⇄ iPhone WatchConnectivity messages |
| `Shared/AppCore` | unified chat store, models, the BLE connection budget planner |
| `Shared/AppleBLE` | Core Bluetooth central hub + per-network transports (Apple only) |
| `WatchApp/` | SwiftUI watch app |
| `iOSBridge/Generic` | WatchBridgeKit sources: companion hub, channel chat service, LAN + MPC transports |
| `iOSBridge/Host` | standalone iPhone host app (dev/testing) |
| `iOSBridge/Upstream` + `upstream-patches/` | how the bridge gets into the real bitchat iOS app |
| `MacTester/` | AppKit test node for macOS 10.14+ (Monocypher crypto, Swift 5.0 syntax) |
| `Tests/Linux` | Linux harness: RFC vectors, upstream Noise vectors, interop between all the implementations |
| `project.yml` | XcodeGen spec (watch, iOS host, Mac tester) |

## Architecture

```
                         ┌──────────────────────────── Apple Watch (watchOS 26) ───────────────────────────┐
                         │  SwiftUI views ── AppModel ── ChatStore (UnifiedMessage / UnifiedPerson)         │
                         │                     │                                                            │
                         │   ┌─────────────────┼───────────────────┬──────────────────────┐                 │
                         │   │ BitchatTransport│ MeshtasticTransport│ MeshCoreTransport    │ CompanionTransport
                         │   │ (leaf engine,   │ (protobuf ToRadio/ │ (companion frames)   │ (WatchConnectivity)
                         │   │  Noise XX DMs)  │  FromRadio)        │                      │                 │
                         │   └───────┬─────────┴─────────┬─────────┴──────────┬───────────┘                 │
                         │       BLECentralHub (central only, ConnectionBudget: ~2 links)  │                 │
                         └───────────┼───────────────────┼────────────────────┼────────────┼─────────────────┘
                              BLE    │            BLE    │             BLE    │            │ WCSession
                     ┌───────────────▼──┐   ┌────────────▼───────┐  ┌─────────▼────────┐   │
                     │ bitchat phone/Mac│   │ Meshtastic radio   │  │ MeshCore radio   │   │
                     │ (peripheral role)│   │ (LoRa)             │  │ (LoRa)           │   │
                     └────────┬─────────┘   └────────────────────┘  └──────────────────┘   │
                              │ bitchat BLE mesh (relays, TTL 7)                            │
                     ┌────────▼─────────────────────────── iPhone ─────────────────────────▼──────────┐
                     │  bitchat app + upstream patch  (or the standalone BitchatWatchHost)            │
                     │   WatchBridgeHub ── CompanionChatSource (bitchat mesh as "bitchat via phone")  │
                     │        └── ChannelChatService ── ChannelRouter ─┬─ LAN  (_hkchan._tcp, TCP)     │
                     │                                                 ├─ MPC  ("hk-chan")              │
                     │                                                 └─ bitchat tunnel (type 0x7E,    │
                     │                                                    opt-in per channel)           │
                     └──────────────────────────────────────────────────────────────────────────────────┘
                                         ▲ LAN / MPC / bitchat BLE
                     ┌───────────────────┴────────── Mac tester (macOS 10.14+) ───────────────────────────┐
                     │ CBPeripheralManager (advertises bitchat service) + CBCentralManager (scans)        │
                     │ BTMeshNode (full node, optional relay) · BTChannelRouter · LAN · MPC · packet log  │
                     └────────────────────────────────────────────────────────────────────────────────────┘
```

### The four transports on the watch

1. **bitchat BLE (leaf).** The watch connects as a central to nearby bitchat phones/Macs and speaks the stock
   wire protocol: signed announces and public messages, Noise XX (`Noise_XX_25519_ChaChaPoly_SHA256`) private
   messages, fragments. It never relays (it has no peripheral role and only ~2 links).
2. **Meshtastic BLE.** The user's chosen Meshtastic radio: primary channel text and DMs via `ToRadio`/`FromRadio`.
3. **MeshCore BLE.** The user's chosen MeshCore companion radio: channel and contact messages.
4. **iPhone companion (WatchConnectivity).** When the iPhone bridge is running, the phone's full bitchat mesh
   and its channel chats show up as separately labelled networks ("bitchat via phone", "channel").

All four run at once; each conversation is labelled with its network and replies go back the same way.

### Channel chat and MultipeerConnectivity

Channel chat is our own small protocol: a short shared code (e.g. `pizza night`) derives a key and an 8-byte channel
ID; messages are ChaCha20-Poly1305 envelopes that travel over **LAN Bonjour/TCP** (`_hkchan._tcp`),
**MultipeerConnectivity** (service `hk-chan`, peer-to-peer Wi-Fi/Bluetooth between Apple devices, discoveryInfo
carries channel IDs, never codes) and, opt-in per channel, **tunnelled through the bitchat mesh** as packet type
`0x7E`. The phone (or Mac tester) runs the router; the watch joins channels through the companion link.
Full spec and security caveats: [docs/wifi-channel.md](docs/wifi-channel.md). **A short code is a weak secret.**

## watchOS limits (why it is shaped like this)

- **Central-only BLE.** watchOS apps can't advertise as a BLE peripheral, so the watch can't be discovered by
  phones; it has to connect out to them. That's why it is a *leaf* node and why a phone/Mac (peripheral role)
  must be nearby for bitchat.
- **About two simultaneous BLE connections.** Apple documents a limit of 2 concurrent peripheral connections
  for watchOS apps. `ConnectionBudget` gives one slot to the user's chosen LoRa radio and the rest to the
  strongest bitchat peers, with hysteresis and back-off.
- **TN3135 networking restrictions.** Per Apple Technote TN3135 (*Low-level networking on watchOS*),
  Network.framework / sockets / Bonjour are only available to watch apps in narrow cases (e.g. active audio
  streaming). So the watch does **no LAN networking itself**; LAN channel chat reaches it through the iPhone.
- **No MultipeerConnectivity on watchOS.** The framework isn't available there; MPC lives on the iPhone/Mac.
- **Background.** `bluetooth-central` background mode is declared, but watchOS background execution is
  tightly budgeted; expect the mesh to be live mainly while the app is frontmost or recently used.

## Build requirements

| Target | Needs |
|--------|-------|
| watch app `BitchatWatch` (watchOS 26.0) | Xcode 26 on macOS 15.6+ (XcodeGen to generate the project) |
| iOS host `BitchatWatchHost` (iOS 26.0) | same |
| Mac tester `BitchatTester` via Xcode project | Xcode 26 (deployment target 10.14; Xcode may warn it is below its supported range) |
| Mac tester via `MacTester/Makefile` | macOS 10.14 Mojave + Command Line Tools for Xcode 10.2/10.3 (Swift 5.0) or 11 (Swift 5.1), or anything newer |
| Linux harness | Swift 6.0.x for Linux (`Tests/Linux/build.sh`) |

```sh
# Apple targets
brew install xcodegen
xcodegen generate
open BitchatWatch.xcodeproj          # set your team, run BitchatWatchHost on the phone + BitchatWatch on the watch

# Mac tester on Mojave (no Xcode project needed)
cd MacTester && make && make run      # -> build/BitchatTester.app

# Linux harness
bash Tests/Linux/build.sh             # SWIFT_BIN=/path/to/usr/bin SYSROOT=... if not on PATH
```

The Swift 5 runtime is part of macOS from **10.14.4**. On 10.14.0–10.14.3 install Apple's *Swift 5 Runtime
Support for Command Line Tools* or update to 10.14.6. Apple targets are built in the Swift 5 language mode;
`Shared/` is also typechecked in Swift 6 mode by the Linux harness (currently clean).

CI (`.github/workflows/build.yml`): macos-15-intel + Xcode 26.x runs XcodeGen and builds all three targets unsigned
(`CODE_SIGNING_ALLOWED=NO`), plus the Makefile tester build; an Ubuntu job runs the Linux harness in
`swift:6.0.3`.

To ship the bridge inside the real bitchat iOS app instead of the dev host, see
[docs/upstream-integration.md](docs/upstream-integration.md).

## Mac tester

`BitchatTester.app` is a full (non-leaf) bitchat node for bench testing:

- **Peripheral**: advertises the bitchat service `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C` (Debug/testnet
  `…4B5A` with `-testnet YES`) with characteristic `A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D`
  (read/write/write-without-response/notify), so the central-only watch can connect to it.
- **Central**: scans for and connects to phones / other testers.
- **Relay** (checkbox, off by default): forwards between all BLE links with TTL−1, dedup and 10–60 ms jitter.
- **Window**: connected peers (bitchat peers, BLE links, MPC/LAN channel peers), packet log (time, direction,
  link, decoded type/summary, hex), chat transcript, public send box, DM-to-selected, channel join / bridge
  toggle / channel send, **Export log…** (⌘E).
- **Channel chat**: MPC `hk-chan` and LAN `_hkchan._tcp` (NetServiceBrowser for discovery, because `NWBrowser`
  is 10.15+; `NWListener`/`NWConnection` for TCP) plus the `0x7E` bitchat tunnel, same router rules as the phone.
- Launch options: `open BitchatTester.app --args -nickname bench1 -testnet YES -freshIdentity YES`.

### Test plan (with the Mac tester)

1. **Wire + announce.** Tester running, watch app open. Expect a `p:` BLE link, an `announce` RX from the watch
   that verifies, and the watch listing the tester as a peer.
2. **Public chat both ways.** Send from each side; check the signed `message` frames in the log and that the
   watch shows the tester's nickname (signature verified).
3. **Noise DM.** Select the watch in the peer list → *DM selected*. Expect `noiseHandshake` ×3, then
   `noiseEncrypted`; the watch shows the DM and the tester logs "delivered". Repeat from the watch side.
4. **Fragmentation.** Send a long DM (~200 chars) with a small-MTU link; check `fragment n/m` entries and reassembly.
5. **Relay.** Two testers (or tester + phone) + watch, relay on in the middle one; message from the far node
   reaches the watch with TTL decremented once.
6. **Interop with stock bitchat.** Phone running release bitchat (or Debug + `-testnet YES`) near the tester:
   announces/public messages verified both ways; DMs between phone and tester.
7. **Channel chat.** Join the same code on tester and iPhone host: LAN and MPC peers appear, messages flow both
   ways; join from the watch via the companion and see them there.
8. **0x7E bridge.** Enable *Bridge channel over bitchat* on one side only; confirm envelopes ≤400 bytes cross
   the BLE mesh, the 4th rapid message is rate-limited (burst 3, then 6/min), and a stock bitchat phone in the
   path relays the unknown type without displaying it.
9. **LoRa (watch only).** Pick a Meshtastic and a MeshCore radio on the watch; send/receive primary-channel text.
10. **Export** the log after each run and attach it to the test notes.

## Known unverified items

These have not been tested on real hardware, and some not compiled:

- **Apple builds**: all three targets now compile in CI (Xcode 26.3, watchOS/iOS 26.2 SDKs: watch app
  arm64 + arm64_32 at watchOS 26.0, iOS host embedding it, Mac tester x86_64 + arm64 at 10.14, plus the
  Makefile x86_64 10.14 build). Compiling is all CI proves: none of it has run on a watch, iPhone or Mac.
- **Mac tester on an actual Mojave machine** with Xcode 10.3/11 CLT: Swift-5.0 syntax was followed by hand
  and only parse-checked with Swift 6; API availability (10.14) was checked against documentation, not a 10.14 SDK.
- **Xcode 26 and a 10.14 deployment target** for the tester's Xcode target: may warn or bump the minimum.
- **Watch PIN pairing for LoRa radios.** Meshtastic/MeshCore require BLE bonding with a PIN; whether watchOS
  shows the system pairing sheet to a third-party app on every watch model is unknown. Workaround if not:
  pair the radio with a fixed PIN and bond once while the app is frontmost, or use the phone.
- **Background BLE on watchOS.** `bluetooth-central` is declared; actual behaviour while the wrist is down is
  unmeasured.
- **Packet type `0x7E` relay risk.** Stock bitchat (iOS 04995f68 / Android cc1fb178) relays unknown broadcast
  types by our reading of the source, but a future upstream version could assign `0x7E`, drop unknown types, or
  rate-limit them. The bridge is opt-in and capped for that reason.
- **XcodeGen embedding** of a single-target watchOS app inside the iOS host (`embed: true`) has not been tried.
- **WatchConnectivity** companion flow, **MPC** invitations and **LAN** discovery have only been exercised as
  pure logic, not between real devices.
- The upstream patch applies to `04995f68`; the Xcode project wiring is manual (see the integration doc).

## Tests

`bash Tests/Linux/build.sh` builds Monocypher, a CryptoKit shim over it, then the shared core, the Mac tester
core and the tests as one module; it also typechecks `Shared/` in Swift 6 mode. Suites: crypto RFC vectors,
bitchat wire format, upstream Noise vectors, the leaf mesh engine, tester ⇄ shared interop (wire, fragments,
Noise both directions, an end-to-end watch ⇄ Mac exchange, channel envelopes and the 0x7E tunnel), Meshtastic
and MeshCore codecs, channel chat, app core, and the Mac tester shell logic (link table, write chunking, LAN
framing, channel adverts, log export).

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for third-party code and protocol credits.
