# Channel chat v1 (`hkchan/v1`)

Local group chat keyed by a short shared **channel code**. It runs over the local network (Bonjour/TCP),
MultipeerConnectivity, and, opt-in per channel, through the bitchat BLE mesh. No servers, no internet.

Reference implementations:

- `Shared/ChannelCore/ChannelProtocol.swift`, `ChannelRouter.swift` (CryptoKit; iPhone/watch)
- `MacTester/Sources/Core/TesterChannel.swift` (Monocypher + CommonCrypto; Mac tester, Swift 5.0)
- transports: `iOSBridge/Generic/LANChannelTransport.swift`, `MPCChannelTransport.swift`,
  `MacTester/Sources/App/ChannelLinks.swift`

Both implementations are cross-checked in `Tests/Linux` (same keys, envelopes open on either side).

> ⚠️ **A short code is a weak secret.** Anyone who knows or guesses the code can read and post. The channel ID is
> derived from the code without a work factor, so an observer who captures one envelope can brute-force short or
> dictionary codes offline. Use channel chat for coordination ("meet at gate B"), not for anything sensitive. Use
> bitchat's Noise DMs for private conversations.

## 1. Keys

```
code      = NFKC(raw) → trim → lowercase → collapse runs of spaces/tabs to one space     (≥ 4 characters)
salt      = "hkchan/v1/salt"
key       = HKDF-SHA256(ikm = UTF-8(code), salt, info = "hkchan/v1/key", L = 32)
channelID = HKDF-SHA256(ikm = UTF-8(code), salt, info = "hkchan/v1/id",  L = 8)
```

`Pizza  Night` and `pizza night` are the same channel. Only `channelID` is ever advertised; the code and the key
never leave the device.

## 2. Envelope

All integers are big-endian.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 4 | magic `"HKC1"` (`48 4B 43 31`) |
| 4 | 1 | version = 1 |
| 5 | 1 | ttl: hops remaining (default **5**, clamped to **7**), **not authenticated** |
| 6 | 8 | channelID |
| 14 | 16 | msgID (random) |
| 30 | 12 | nonce (random) |
| 42 | n+16 | ChaCha20-Poly1305 ciphertext ‖ 16-byte tag |

- AEAD: ChaCha20-Poly1305 (RFC 8439, IETF 96-bit nonce) with `key`, `nonce`,
  `aad = bytes[0..5) ‖ bytes[6..30)` (everything in the header except the TTL byte and the nonce).
  Relays can decrement TTL without re-sealing; every other header field is bound to the ciphertext.
- Inner plaintext: `originID(8) ‖ timestampMs(8) ‖ kind(1) ‖ nickLen(1) ‖ nick ‖ body`
  - `kind`: 1 = text, 2 = hello (presence; never bridged, ttl 1), 3 = leave
  - nick ≤ 32 bytes, body ≤ 280 bytes UTF-8 (cut on a character boundary)
- Size: minimum 58 bytes, maximum accepted 4096 bytes. A max-size text is ~388 bytes, under the 400-byte bridge cap.
- Random 96-bit nonces under one key are safe for far more messages than a chat channel will ever carry.

## 3. Transports

| Path | Discovery | Framing | Notes |
|------|-----------|---------|-------|
| LAN | Bonjour `_hkchan._tcp`, TXT `v=1`, `c=<csv of channelID hex>` (≤16) | TCP, 4-byte BE length + envelope | the side with the smaller instance name dials; no TLS (envelopes are already sealed) |
| MPC | MultipeerConnectivity service `hk-chan`, discoveryInfo `v=1`, `c=<csv>` | one MPC message = one envelope | `.required` encryption; the smaller displayName invites; invitation context carries the inviter's channel IDs |
| bitchat | packet type `0x7E`, broadcast, unsigned | one bitchat packet payload = one envelope | opt-in per channel, see §6 |

On the Mac tester (macOS 10.14), LAN discovery uses `NetServiceBrowser` + TXT resolution because `NWBrowser` and
`NWTXTRecord` are 10.15+. The listener and connections are Network.framework. The wire is the same.

The watch has none of these itself (TN3135: no general-purpose networking on watchOS, and no
MultipeerConnectivity). It sees channels through the iPhone companion bridge.

## 4. Receiving

1. Parse the header; drop if magic/version/size are wrong.
2. Drop if `channelID` is not one we joined (we can't open it and don't forward it).
3. Drop if `msgID` is in the dedup cache.
4. Open the AEAD; on failure drop and log (not cached, so a forged copy can't block the real one).
5. Insert `msgID` into the dedup cache; drop our own `originID`; deliver.
6. Forward (§5).

## 5. Forwarding, TTL, dedup

- **TTL:** default 5 on send, clamped to 7 everywhere. A receiver forwards with `ttl − 1` and only if `ttl > 1`.
  `hello` is never forwarded.
- **Dedup:** bounded set of the last **4096** msgIDs per device (FIFO eviction). Every msgID is delivered and
  forwarded at most once, whatever path it came in on.
- **LAN / MPC:** forwarded to every other LAN and MPC link except the one it arrived on.
- **Only joined channels are forwarded.** A device is never a blind relay for channels it can't read.

## 6. The bitchat bridge (opt-in)

A channel can be bridged into the bitchat BLE mesh so people who share the code but aren't on the same Wi-Fi can
still talk. It's **off by default, per channel**, and limited:

- only `text` and `leave` kinds; never `hello`
- never forwarded *back* into bitchat (an envelope that arrived via bitchat only goes to LAN/MPC)
- **envelope ≤ 400 bytes**, so it fits a typical BLE write on phone links and stock relays don't have to fragment
  an unknown type
- **rate limit:** a token bucket shared by all channels on the device: **burst 3, then 6 per minute**
- the bitchat packet: type `0x7E`, broadcast, unsigned, `ttl = min(envelope ttl, 7)`; the bitchat TTL and the
  envelope TTL are separate counters

### Why a new packet type (`0x7E`) and not public messages

- **Stock clients would display garbage.** A public message (`0x02`) is shown to every bitchat user in range.
  Envelopes would appear as binary noise in everyone's public chat.
- **Signatures and identity.** Public messages are signed with the sender's announced Ed25519 key and attributed
  to a nickname; channel chat has its own identity (originID) and shouldn't spend or leak the bitchat one.
- **Relays still carry it.** By our reading of upstream (iOS `04995f68`, Android `cc1fb178`), unknown broadcast
  types are relayed with the normal TTL/dedup rules, just not handled. `0x7E` was unassigned in both. The
  upstream patch adds an observer for unknown types and a `broadcastOpaque` that refuses core types.
- **Easy to remove or filter.** If upstream ever objects, one type number can be dropped without touching chat.

Risk: a future upstream version could assign `0x7E`, stop relaying unknown types, or rate-limit them. That's why
the bridge is opt-in, capped and rate-limited, and listed as unverified in the README.

## 7. Test vectors

`Tests/Linux/Tests` seals with fixed msgID/nonce and checks the shared and tester implementations produce
byte-identical envelopes and open each other's, including the `0x7E` tunnel into the watch's leaf engine.
