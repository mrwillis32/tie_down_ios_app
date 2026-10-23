import SwiftUI

/// More › App Settings › Card Readers: choose Tap to Pay or a Bluetooth reader, scan, connect, update.
struct CardReaderSettingsView: View {
    @EnvironmentObject private var terminal: TerminalManager
    @State private var connectingSerial: String?
    @State private var tapToPayError: String?

    var body: some View {
        Form {
            Section {
                Picker("Use for card payments", selection: $terminal.preferredKind) {
                    ForEach(ReaderKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
            } footer: {
                Text("The POS uses this reader unless you pick another at checkout.")
            }

            connectedSection

            Section {
                HStack {
                    Label("Tap to Pay on iPhone", systemImage: "wave.3.right.circle")
                    Spacer()
                    if terminal.isConnecting, terminal.connectedKind == nil, connectingSerial == nil {
                        ProgressView()
                    } else if terminal.connectedKind == .tapToPay {
                        Text("Ready").foregroundStyle(.green)
                    }
                }
                if terminal.connectedKind != .tapToPay {
                    Button("Set Up Tap to Pay") {
                        tapToPayError = nil
                        Task {
                            do { try await terminal.prepare() } catch { tapToPayError = error.localizedDescription }
                        }
                    }
                    .disabled(terminal.isConnecting)
                }
                if let tapToPayError {
                    Text(tapToPayError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("This iPhone")
            } footer: {
                Text("Accept contactless cards and Apple Pay with no extra hardware. Requires iPhone XS or later.")
            }

            bluetoothSection

            if let message = terminal.statusMessage {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Card Readers")
        .onDisappear { terminal.stopScan() }
    }

    @ViewBuilder
    private var connectedSection: some View {
        if let name = terminal.connectedReaderName {
            Section("Connected") {
                HStack(spacing: 12) {
                    Image(systemName: terminal.connectedKind == .tapToPay ? "iphone.radiowaves.left.and.right" : "creditcard.and.123")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.headline)
                        if let battery = terminal.batteryPercent {
                            Label("\(battery)% battery", systemImage: Self.batteryIcon(battery))
                                .font(.caption)
                                .foregroundStyle(battery < 20 ? .red : .secondary)
                        }
                    }
                }
                if terminal.updateAvailable {
                    Button {
                        terminal.installAvailableUpdate()
                    } label: {
                        Label("Install reader update", systemImage: "arrow.down.circle")
                    }
                }
                Button("Disconnect", role: .destructive) {
                    Task { await terminal.disconnect() }
                }
            }
        }
    }

    private var bluetoothSection: some View {
        Section {
            if let saved = terminal.savedBluetoothSerial, terminal.connectedKind != .bluetooth {
                HStack {
                    Label("Saved reader \(saved)", systemImage: "creditcard")
                    Spacer()
                    Button("Reconnect") { Task { await terminal.reconnectSavedReader() } }
                        .disabled(terminal.isScanning || terminal.isConnecting)
                }
                .swipeActions {
                    Button("Forget", role: .destructive) { Task { await terminal.forgetBluetoothReader() } }
                }
            }

            ForEach(terminal.discoveredReaders) { reader in
                Button {
                    connectingSerial = reader.id
                    Task {
                        _ = try? await terminal.connectBluetooth(serial: reader.id)
                        connectingSerial = nil
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reader.label).foregroundStyle(.primary)
                            Text(reader.model + (reader.simulated ? " · simulated" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connectingSerial == reader.id {
                            ProgressView()
                        } else if let battery = reader.batteryPercent {
                            Text("\(battery)%").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(terminal.isConnecting)
            }

            if terminal.isScanning {
                HStack {
                    ProgressView()
                    Text("Scanning… turn your reader on and keep it nearby.").foregroundStyle(.secondary)
                }
                Button("Stop Scanning") { terminal.stopScan() }
            } else {
                Button {
                    Task { await terminal.startBluetoothScan() }
                } label: {
                    Label("Scan for Readers", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(terminal.isConnecting)
            }

            if let error = terminal.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Bluetooth readers")
        } footer: {
            Text("Works with Stripe M2, BBPOS WisePad 3 and Chipper 2X BT. Once connected, the reader reconnects automatically next time.")
        }
    }

    private static func batteryIcon(_ percent: Int) -> String {
        switch percent {
        case ..<15: "battery.0percent"
        case ..<40: "battery.25percent"
        case ..<65: "battery.50percent"
        case ..<90: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
