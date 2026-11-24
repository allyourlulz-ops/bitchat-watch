//
// Views.swift — bitchat-watch watch UI
//
// Three vertical pages: Inbox (every conversation, each with a network badge),
// People (per network, favorites first), Radios (status, LoRa radio choice,
// channel chat via iPhone, settings). Conversation view with a TextField
// (dictation / Scribble / keyboard on watchOS).
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            if model.needsNickname {
                NicknameView()
            } else {
                TabView {
                    InboxView()
                    PeopleView()
                    RadiosView()
                }
                .tabViewStyle(.verticalPage)
            }
        }
    }
}

struct NetworkBadge: View {
    let network: NetworkKind
    var bridged = false

    var color: Color {
        switch network {
        case .bitchat, .bitchatPhone: return .green
        case .meshtastic: return .mint
        case .meshcore: return .orange
        case .channel: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(network.badge)
            if bridged { Image(systemName: "point.3.connected.trianglepath.dotted") }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(color.opacity(0.25), in: Capsule())
        .foregroundStyle(color)
        .accessibilityLabel(bridged ? "\(network.shortLabel), bridged" : network.shortLabel)
    }
}

struct NicknameView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""

    var body: some View {
        VStack(spacing: 8) {
            Text("bitchat").font(.title3.monospaced()).foregroundStyle(.green)
            Text("Pick a nickname others will see").font(.footnote).multilineTextAlignment(.center)
            TextField("nickname", text: $name)
            Button("Start") { model.setNickname(name) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }
}

struct InboxView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let _ = model.revision
        List {
            if model.bluetoothOff {
                Label("Bluetooth is off or not allowed", systemImage: "exclamationmark.triangle").font(.footnote)
            }
            ForEach(model.store.summaries()) { s in
                NavigationLink(value: s.conversation) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            NetworkBadge(network: s.conversation.network, bridged: s.bridged)
                            if s.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                            Text(s.title).font(.headline).lineLimit(1)
                            Spacer(minLength: 0)
                            if s.unread > 0 {
                                Text("\(s.unread)").font(.caption2.bold()).padding(.horizontal, 5)
                                    .background(.green, in: Capsule()).foregroundStyle(.black)
                            }
                        }
                        if !s.lastText.isEmpty { Text(s.lastText).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
        }
        .navigationTitle("Inbox")
        .navigationDestination(for: ConversationID.self) { ConversationView(conversation: $0) }
    }
}

struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    let conversation: ConversationID
    @State private var draft = ""

    var body: some View {
        let _ = model.revision
        let messages = model.store.messages[conversation] ?? []
        ScrollViewReader { proxy in
            List {
                Section {
                    HStack {
                        NetworkBadge(network: conversation.network, bridged: model.store.rooms[conversation]?.bridged ?? false)
                        Text(conversation.scope == .direct ? (conversation.network == .bitchat ? "Noise DM" : "Direct") : "Channel")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(messages) { m in
                    MessageRow(message: m).id(m.id)
                }
                if model.canSend(in: conversation) {
                    TextField("Message", text: $draft)
                        .onSubmit {
                            model.send(draft, in: conversation)
                            draft = ""
                        }
                } else {
                    Text("Not connected to this network").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .onAppear {
                model.open(conversation)
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onDisappear { model.close(conversation) }
            .onChange(of: messages.count) { _, _ in
                model.store.markRead(conversation)
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .navigationTitle(model.store.title(for: conversation))
    }
}

struct MessageRow: View {
    let message: UnifiedMessage

    var stateIcon: String {
        switch message.state {
        case .sending: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark.circle"
        case .read: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .received: return ""
        }
    }

    var body: some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(message.outgoing ? "me" : message.senderName).font(.caption2.bold())
                    .foregroundStyle(message.outgoing ? .orange : .green)
                if message.bridged { NetworkBadge(network: .channel, bridged: true) }
                Text(message.timestamp, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(message.text).font(.body)
            if message.outgoing || message.via != nil {
                HStack(spacing: 3) {
                    if let via = message.via { Text(via).font(.system(size: 9)).foregroundStyle(.secondary) }
                    if !stateIcon.isEmpty { Image(systemName: stateIcon).font(.system(size: 9)) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
    }
}

struct PeopleView: View {
    @EnvironmentObject var model: AppModel
    @State private var openDM: ConversationID?

    var body: some View {
        let _ = model.revision
        List {
            ForEach([NetworkKind.bitchat, .bitchatPhone, .meshtastic, .meshcore], id: \.self) { net in
                let people = model.store.sortedPeople(network: net)
                if !people.isEmpty {
                    Section(net.shortLabel) {
                        ForEach(people) { p in
                            HStack {
                                Button {
                                    if p.canMessage { openDM = model.startDM(with: p) }
                                } label: {
                                    VStack(alignment: .leading) {
                                        HStack(spacing: 3) {
                                            Circle().fill(p.isOnline ? .green : .gray).frame(width: 6, height: 6)
                                            Text(p.displayName).lineLimit(1)
                                            if p.secureSession { Image(systemName: "lock.fill").font(.system(size: 9)) }
                                        }
                                        Text(p.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer(minLength: 0)
                                Button { model.toggleFavorite(p) } label: {
                                    Image(systemName: p.isFavorite ? "star.fill" : "star").foregroundStyle(.yellow)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(p.isFavorite ? "Unfavorite" : "Favorite")
                            }
                        }
                    }
                }
            }
            if model.store.people.isEmpty {
                Text("No one nearby yet").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("People")
        .navigationDestination(item: $openDM) { ConversationView(conversation: $0) }
    }
}

struct RadiosView: View {
    @EnvironmentObject var model: AppModel
    @State private var channelCode = ""
    @State private var bridgeNew = false

    var body: some View {
        let _ = model.revision
        List {
            Section("Status") {
                ForEach(model.statusLines) { line in
                    HStack(alignment: .top) {
                        NetworkBadge(network: line.network)
                        Text(line.text).font(.caption2)
                    }
                }
                Text("BLE links: \(model.hub.connectedCount)/\(model.hub.policy.maxConnections)").font(.caption2).foregroundStyle(.secondary)
            }
            Section("LoRa radio") {
                let current = model.settings.preferredRadioID
                if current != nil {
                    HStack {
                        Text(model.settings.preferredRadioName).lineLimit(1)
                        Spacer()
                        Button("Forget") { model.choose(radio: nil) }.font(.caption2)
                    }
                }
                Toggle("Find radios", isOn: Binding(get: { model.hub.discoverRadios }, set: { model.hub.discoverRadios = $0 }))
                if model.hub.discoverRadios {
                    ForEach(model.hub.candidates(of: .meshtastic) + model.hub.candidates(of: .meshcore), id: \.id) { c in
                        Button {
                            model.choose(radio: c)
                            model.hub.discoverRadios = false
                        } label: {
                            HStack {
                                NetworkBadge(network: c.kind == .meshtastic ? .meshtastic : .meshcore)
                                Text(c.name).lineLimit(1)
                                Spacer()
                                Text("\(c.rssi)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Channel chat (via iPhone)") {
                TextField("channel code", text: $channelCode)
                Toggle("Bridge into bitchat", isOn: $bridgeNew)
                Button("Join") {
                    model.companion.joinChannel(code: channelCode, bridge: bridgeNew)
                    channelCode = ""
                }
                .disabled(channelCode.count < ChannelKeys.minimumCodeLength || !model.companion.activated)
                ForEach(model.store.rooms.values.filter { $0.conversation.network == .channel }.sorted { $0.title < $1.title }) { r in
                    HStack {
                        NetworkBadge(network: .channel, bridged: r.bridged)
                        Text(r.title).lineLimit(1)
                    }
                    .swipeActions {
                        Button(r.bridged ? "Unbridge" : "Bridge") {
                            model.companion.setBridge(idHex: r.conversation.key, enabled: !r.bridged)
                        }
                        Button("Leave", role: .destructive) { model.companion.leaveChannel(idHex: r.conversation.key) }
                    }
                }
                Text("Codes are weak shared secrets — don't use channel chat for anything sensitive.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Section("Settings") {
                Toggle("Direct bitchat mesh", isOn: Binding(get: { model.settings.directBitchat }, set: { model.setDirectBitchat($0) }))
                Toggle("Notifications", isOn: Binding(get: { model.settings.notifications }, set: { model.setNotifications($0) }))
                Text("bitchat ID \(model.bitchat.engine.myPeerID.id)").font(.system(size: 9, design: .monospaced))
                Text("fingerprint \(model.bitchat.engine.identity.fingerprint.prefix(16))…").font(.system(size: 9, design: .monospaced))
            }
        }
        .navigationTitle("Radios")
    }
}
