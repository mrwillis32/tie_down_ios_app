import SwiftUI
import UIKit

/// More › App Settings › Printers: add AirPrint, network and Bluetooth receipt printers, pick the
/// default, and print a test page.
struct PrinterSettingsView: View {
    @EnvironmentObject private var printers: PrinterManager
    @State private var addingNetwork = false
    @State private var addingBluetooth = false
    @State private var message: String?
    @State private var testingId: UUID?

    var body: some View {
        List {
            Section {
                if printers.printers.isEmpty {
                    Text("No printers yet. Receipts will open the iOS print sheet until you add one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(printers.printers) { printer in
                    NavigationLink {
                        PrinterDetailView(printerId: printer.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: Self.icon(for: printer.connection))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(printer.name)
                                Text(printer.connection.summary + (printer.connection.isReceiptPrinter ? " · \(printer.paperWidthMM) mm" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if printer.id == printers.defaultPrinter?.id {
                                Text("Default").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { printers.printers[$0].id }.forEach(printers.remove)
                }
            } header: {
                Text("Printers")
            } footer: {
                Text("Receipts print on the default printer. Reports and other pages always use AirPrint.")
            }

            Section("Add a printer") {
                Button {
                    pickAirPrinter()
                } label: {
                    Label("AirPrint printer", systemImage: "printer")
                }
                Button {
                    addingNetwork = true
                } label: {
                    Label("Network receipt printer", systemImage: "network")
                }
                Button {
                    addingBluetooth = true
                } label: {
                    Label("Bluetooth receipt printer", systemImage: "antenna.radiowaves.left.and.right")
                }
            }

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Printers")
        .toolbar { EditButton() }
        .sheet(isPresented: $addingNetwork) {
            NavigationStack { AddNetworkPrinterView(browser: printers.networkBrowser) }
        }
        .sheet(isPresented: $addingBluetooth) {
            NavigationStack { AddBluetoothPrinterView(central: printers.bluetooth) }
        }
    }

    private func pickAirPrinter() {
        let picker = UIPrinterPickerController(initiallySelectedPrinter: nil)
        let completion: UIPrinterPickerController.CompletionHandler = { controller, selected, _ in
            guard selected, let printer = controller.selectedPrinter else { return }
            Task { @MainActor in
                printers.add(SavedPrinter(name: printer.displayName, connection: .airPrint(url: printer.url)))
                message = "Added \(printer.displayName)."
            }
        }
        if UIDevice.current.userInterfaceIdiom == .pad, let view = Presenter.topViewController()?.view {
            let rect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            picker.present(from: rect, in: view, animated: true, completionHandler: completion)
        } else {
            picker.present(animated: true, completionHandler: completion)
        }
    }

    static func icon(for connection: SavedPrinter.Connection) -> String {
        switch connection {
        case .airPrint: "printer"
        case .network, .bonjour: "printer.dotmatrix"
        case .bluetooth: "printer.dotmatrix.fill"
        }
    }
}

// MARK: - Printer detail

private struct PrinterDetailView: View {
    let printerId: UUID
    @EnvironmentObject private var printers: PrinterManager
    @Environment(\.dismiss) private var dismiss
    @State private var result: String?
    @State private var testing = false

    private var printer: SavedPrinter? { printers.printers.first { $0.id == printerId } }

    var body: some View {
        Form {
            if let printer {
                Section {
                    TextField("Name", text: binding(\.name, printer))
                    LabeledContent("Connection", value: printer.connection.summary)
                    if printer.id != printers.defaultPrinter?.id {
                        Button("Make Default") { printers.setDefault(printer.id) }
                    } else {
                        Label("Default printer", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }

                if printer.connection.isReceiptPrinter {
                    Section("Receipt printer") {
                        Picker("Paper width", selection: binding(\.paperWidthMM, printer)) {
                            Text("58 mm").tag(58)
                            Text("80 mm").tag(80)
                        }
                        Toggle("Cut paper after each receipt", isOn: binding(\.autoCut, printer))
                        Toggle("Open cash drawer after cash sales", isOn: binding(\.openCashDrawer, printer))
                    }
                }

                Section {
                    Button {
                        testing = true
                        result = nil
                        Task {
                            do {
                                try await printers.printTestPage(printer)
                                result = "Test page sent."
                            } catch {
                                result = error.localizedDescription
                            }
                            testing = false
                        }
                    } label: {
                        HStack {
                            Label("Print Test Page", systemImage: "doc.text")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if let result {
                        Text(result).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Remove Printer", role: .destructive) {
                        printers.remove(printer.id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(printer?.name ?? "Printer")
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SavedPrinter, T>, _ printer: SavedPrinter) -> Binding<T> {
        Binding(
            get: { (printers.printers.first { $0.id == printer.id } ?? printer)[keyPath: keyPath] },
            set: { value in
                var updated = printers.printers.first { $0.id == printer.id } ?? printer
                updated[keyPath: keyPath] = value
                printers.update(updated)
            }
        )
    }
}

// MARK: - Add network printer

private struct AddNetworkPrinterView: View {
    @ObservedObject var browser: NetworkPrinterBrowser
    @EnvironmentObject private var printers: PrinterManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Receipt Printer"
    @State private var host = ""
    @State private var port = "9100"
    @State private var paperWidth = 80
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if browser.found.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Looking for receipt printers on this network…").foregroundStyle(.secondary)
                    }
                }
                ForEach(browser.found) { found in
                    Button {
                        save(SavedPrinter(
                            name: found.name,
                            connection: .bonjour(name: found.name, type: found.type, domain: found.domain),
                            paperWidthMM: paperWidth
                        ))
                    } label: {
                        Label(found.name, systemImage: "printer.dotmatrix")
                    }
                }
            } header: {
                Text("Found on this network")
            }

            Section {
                TextField("Name", text: $name)
                TextField("IP address (e.g. 192.168.1.50)", text: $host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port).keyboardType(.numberPad)
                Picker("Paper width", selection: $paperWidth) {
                    Text("58 mm").tag(58)
                    Text("80 mm").tag(80)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("Enter address")
            } footer: {
                Text("Epson TM, Star TSP and most Ethernet/Wi-Fi receipt printers use port 9100. Print the printer's self-test page to find its IP address.")
            }
        }
        .navigationTitle("Network Printer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { addManual() }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func addManual() {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard let portNumber = UInt16(port), portNumber > 0 else {
            error = "Enter a port between 1 and 65535."
            return
        }
        save(SavedPrinter(
            name: name.isEmpty ? trimmedHost : name,
            connection: .network(host: trimmedHost, port: portNumber),
            paperWidthMM: paperWidth
        ))
    }

    private func save(_ printer: SavedPrinter) {
        printers.add(printer)
        dismiss()
    }
}

// MARK: - Add Bluetooth printer

private struct AddBluetoothPrinterView: View {
    let central: BluetoothPrinterCentral
    @EnvironmentObject private var printers: PrinterManager
    @Environment(\.dismiss) private var dismiss
    @State private var paperWidth = 58

    var body: some View {
        BluetoothPrinterList(central: central, paperWidth: $paperWidth) { found in
            printers.add(SavedPrinter(
                name: found.name,
                connection: .bluetooth(peripheralId: found.id),
                paperWidthMM: paperWidth
            ))
            dismiss()
        }
        .navigationTitle("Bluetooth Printer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }
}

private struct BluetoothPrinterList: View {
    @ObservedObject var central: BluetoothPrinterCentral
    @Binding var paperWidth: Int
    let onPick: (BluetoothPrinterCentral.Found) -> Void

    var body: some View {
        Form {
            Section {
                Picker("Paper width", selection: $paperWidth) {
                    Text("58 mm").tag(58)
                    Text("80 mm").tag(80)
                }
            }
            Section {
                ForEach(central.found) { found in
                    Button {
                        central.stopScan()
                        onPick(found)
                    } label: {
                        HStack {
                            Label(found.name, systemImage: "printer.dotmatrix")
                            Spacer()
                            Text("\(found.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if central.isScanning {
                    HStack {
                        ProgressView()
                        Text("Scanning… turn the printer on and make sure it isn't paired to another device.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Scan Again") { Task { await central.startScan() } }
                }
            } header: {
                Text("Nearby devices")
            } footer: {
                Text("For Bluetooth LE receipt printers (most 58 mm portable printers). Pick yours, then use Print Test Page to check it.")
            }
        }
        .task { await central.startScan() }
        .onDisappear { central.stopScan() }
    }
}
