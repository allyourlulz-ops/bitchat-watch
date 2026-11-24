#!/usr/bin/env bash
# Generates upstream-patches/0001-watch-companion-bridge.patch against a clean
# checkout of permissionlesstech/bitchat (tested against 04995f68).
#
#   scripts/make-upstream-patch.sh /path/to/bitchat [output.patch]
#
# The patch is purely additive except for five small hooks:
#   * BLEService: `opaquePacketObserver` (unknown packet types) + `broadcastOpaque(type:payload:ttl:)`
#   * ChatOutgoingCoordinator/ChatViewModel: `sendMeshText(_:)`
#   * AppRuntime.start(): creates and starts the watch bridge (iOS only)
#   * Info.plist: NSLocalNetworkUsageDescription + NSBonjourServices
# and adds localPackages/WatchBridgeKit (internal copies of our shared code, one public façade)
# plus bitchat/WatchBridge/BitchatWatchBridgeAdapter.swift.
# Xcode project wiring (local package dependency + watch target) is manual: see docs/upstream-integration.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UP="${1:?path to bitchat checkout}"
OUT="${2:-$ROOT/upstream-patches/0001-watch-companion-bridge.patch}"
cd "$UP"
git diff --quiet || { echo "upstream checkout is dirty"; exit 1; }

PKG=localPackages/WatchBridgeKit
mkdir -p "$PKG/Sources/WatchBridgeKit" bitchat/WatchBridge
cat > "$PKG/Package.swift" <<'EOF'
// swift-tools-version: 5.9
// WatchBridgeKit — Apple Watch companion bridge + local channel chat for bitchat iOS.
// GPL-3.0-or-later (see LICENSE/NOTICE in bitchat-watch). Internal copies of
// bitchat-watch Shared/ code; only WatchBridgePublic.swift is public.
import PackageDescription
let package = Package(
    name: "WatchBridgeKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "WatchBridgeKit", targets: ["WatchBridgeKit"])],
    targets: [.target(name: "WatchBridgeKit", path: "Sources/WatchBridgeKit")]
)
EOF
S="$PKG/Sources/WatchBridgeKit"
for f in \
  Shared/AppCore/UnifiedModels.swift Shared/Companion/CompanionProtocol.swift \
  Shared/ChannelCore/ChannelProtocol.swift Shared/ChannelCore/ChannelRouter.swift Shared/ChannelCore/ChannelSupport.swift \
  Shared/BitchatCore/Upstream/Data+Hex.swift Shared/BitchatCore/Upstream/String+Ext.swift Shared/BitchatCore/Upstream/Data+SHA256.swift \
  Shared/BitchatCore/Support/UpstreamShims.swift \
  iOSBridge/Generic/ChannelChatService.swift iOSBridge/Generic/LANChannelTransport.swift \
  iOSBridge/Generic/MPCChannelTransport.swift iOSBridge/Generic/WatchBridgeHub.swift \
  iOSBridge/Package/WatchBridgePublic.swift ; do
  cp "$ROOT/$f" "$S/"
done
# keep helper extensions internal to avoid ambiguity with BitFoundation's public ones
sed -i.bak 's/^public extension /extension /' "$S"/Data+Hex.swift "$S"/String+Ext.swift "$S"/Data+SHA256.swift && rm -f "$S"/*.bak
cp "$ROOT/iOSBridge/Upstream/BitchatWatchBridgeAdapter.swift" bitchat/WatchBridge/

python3 - <<'PY'
import re, pathlib
def edit(path, old, new, count=1):
    p = pathlib.Path(path); s = p.read_text()
    assert old in s, f"anchor not found in {path}: {old[:60]!r}"
    p.write_text(s.replace(old, new, count))

ble = "bitchat/Services/BLE/BLEService.swift"
edit(ble, """        case .none:
            SecureLogger.warning("⚠️ Unknown message type: \\(packet.type)", category: .session)
        }""", """        case .none:
            SecureLogger.warning("⚠️ Unknown message type: \\(packet.type)", category: .session)
            // bitchat-watch: surface opaque types (e.g. 0x7E channel tunnel) to an observer;
            // relaying below is unchanged.
            opaquePacketObserver?(packet.type, packet.payload, senderID)
        }""")
edit(ble, """    func sendPacket(to peerID: PeerID, packet: BitchatPacket) {""", """    /// bitchat-watch: broadcast an unsigned opaque payload of a non-core type
    /// (used by the watch companion's channel-chat bridge, type 0x7E).
    func broadcastOpaque(type: UInt8, payload: Data, ttl: UInt8) {
        guard MessageType(rawValue: type) == nil else { return } // never forge core types
        onEngine {
            let packet = BitchatPacket(
                type: type,
                senderID: myPeerIDData,
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: min(ttl, messageTTL)
            )
            broadcastPacket(packet)
        }
    }

    func sendPacket(to peerID: PeerID, packet: BitchatPacket) {""")

edit(ble, """    private let localIdentityState = BLELocalIdentityStateStore()""", """    private let localIdentityState = BLELocalIdentityStateStore()
    /// bitchat-watch: observer for packet types this build doesn't understand
    /// (called on the engine queue for every unknown type, before relay).
    var opaquePacketObserver: ((UInt8, Data, PeerID) -> Void)?""")
edit("bitchat/ViewModels/ChatOutgoingCoordinator.swift", """    /// Broadcasts a wave on the mesh channel regardless of the active channel —""", """    /// bitchat-watch: send text to the mesh channel regardless of the active channel.
    func sendMeshText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendMeshPublicMessage(originalContent: trimmed, trimmed: trimmed, mentions: [])
    }

    /// Broadcasts a wave on the mesh channel regardless of the active channel —""")
edit("bitchat/ViewModels/ChatViewModel.swift", """    /// Sends a 👋 to the mesh channel regardless of the active channel.
    @MainActor
    func sendMeshWave() {""", """    /// bitchat-watch: send text to the mesh channel regardless of the active channel.
    @MainActor
    func sendMeshText(_ text: String) {
        outgoingCoordinator.sendMeshText(text)
    }

    /// Sends a 👋 to the mesh channel regardless of the active channel.
    @MainActor
    func sendMeshWave() {""")

rt = "bitchat/App/AppRuntime.swift"
edit(rt, """    private var started = false""", """    private var started = false
    #if os(iOS)
    /// bitchat-watch companion bridge (WatchConnectivity + local channel chat).
    private var watchBridgeAdapter: BitchatWatchBridgeAdapter?
    #endif""")
edit(rt, """        started = true
""", """        started = true
        #if os(iOS)
        let watchBridge = BitchatWatchBridgeAdapter(chatViewModel: chatViewModel)
        watchBridgeAdapter = watchBridge
        watchBridge.start()
        #endif
""")

pl = "bitchat/Info.plist"
edit(pl, """	<key>NSCameraUsageDescription</key>""", """	<key>NSBonjourServices</key>
	<array>
		<string>_hkchan._tcp</string>
		<string>_hk-chan._tcp</string>
		<string>_hk-chan._udp</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
	<string>bitchat uses the local network for offline channel chat with nearby devices and to reach your Apple Watch.</string>
	<key>NSCameraUsageDescription</key>""")
PY

git add -N "$PKG" bitchat/WatchBridge
git diff > "$OUT"
git reset -q
git checkout -q -- .
rm -rf "$PKG" bitchat/WatchBridge
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
