import SwiftUI

struct OverviewScreen: View {
    @EnvironmentObject var client: Client

    private var snapshot: Snapshot? { client.snapshot }

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let snapshot {
                    VStack(alignment: .leading, spacing: 26) {
                        alerts(snapshot)
                        system(snapshot)
                        storage(snapshot)
                        footer(snapshot)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                } else {
                    Waiting(state: client.state)
                        .padding(.top, 90)
                }
            }
            .refreshable { await client.refreshOnce() }
            .navigationTitle(snapshot?.host.hostname ?? "Vitals")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { LiveBadge() } }
        }
    }

    // MARK: Alerts

    @ViewBuilder
    private func alerts(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Needs attention")
            if snapshot.alerts.isEmpty {
                Card(padding: 14) {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.good)
                        Text("All clear.")
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(snapshot.containers.count) containers, \(snapshot.disks.count) filesystems.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshot.alerts) { alert in
                        AlertRow(alert: alert)
                    }
                }
            }
        }
    }

    // MARK: System

    private func system(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "System",
                         trailing: "up \(Fmt.uptime(snapshot.host.uptime))")
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(
                    label: "CPU",
                    value: String(format: "%.0f", snapshot.cpu.percent),
                    unit: "%",
                    detail: "load \(loadText(snapshot)) · \(snapshot.cpu.count) cores",
                    fraction: snapshot.cpu.percent / 100,
                    tint: Palette.level(snapshot.cpu.percent, warn: 70, crit: 90),
                    series: client.history.cpu, ceiling: 100)

                StatTile(
                    label: "Memory",
                    value: Fmt.split(snapshot.memory.used).0,
                    unit: Fmt.split(snapshot.memory.used).1,
                    detail: "of \(Fmt.bytes(snapshot.memory.total)) · \(Int(snapshot.memory.percent))%",
                    fraction: snapshot.memory.percent / 100,
                    tint: Palette.level(snapshot.memory.percent, warn: 85, crit: 95),
                    series: client.history.memory, ceiling: 100)

                StatTile(
                    label: "Temperature",
                    value: snapshot.cpu.temp.map { String(format: "%.0f", $0) } ?? "—",
                    unit: snapshot.cpu.temp == nil ? nil : "°C",
                    detail: snapshot.memory.swap.total > 0
                        ? "swap \(Int(snapshot.memory.swap.percent))%" : "no swap",
                    fraction: snapshot.cpu.temp.map { min($0, 100) / 100 },
                    tint: Palette.level(snapshot.cpu.temp ?? 0, warn: 75, crit: 88))

                let net = snapshot.network.first
                let throughput = (net?.rx_rate ?? 0) + (net?.tx_rate ?? 0)
                StatTile(
                    label: "Network",
                    value: Fmt.rate(throughput).0,
                    unit: Fmt.rate(throughput).1,
                    detail: net.map {
                        "↓\(Fmt.rate($0.rx_rate).0) ↑\(Fmt.rate($0.tx_rate).0) \($0.name)"
                    } ?? "—",
                    tint: Palette.warm,
                    series: client.history.network)
            }
        }
    }

    private func loadText(_ snapshot: Snapshot) -> String {
        snapshot.cpu.load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " ")
    }

    // MARK: Storage

    private func storage(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Storage", trailing: "\(snapshot.disks.count) mounted")
            VStack(spacing: 12) {
                ForEach(snapshot.disks) { disk in
                    DiskCard(disk: disk, smart: snapshot.smart(for: disk))
                }
            }
        }
    }

    // MARK: Footer

    private func footer(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(snapshot.host.os) · \(snapshot.host.kernel)")
                .font(.system(size: 12, design: .monospaced))
            Text("The agent samples only while this screen is open. Close the app and it stops.")
                .font(.system(size: 12))
        }
        .foregroundStyle(.tertiary)
        .padding(.top, 4)
    }
}

struct AlertRow: View {
    let alert: Snapshot.Alert

    var body: some View {
        HStack(spacing: 11) {
            Capsule()
                .fill(alert.critical ? Palette.rose : Palette.warm)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.subject)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(alert.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline))
    }
}

struct DiskCard: View {
    let disk: Snapshot.Disk
    let smart: Snapshot.SmartDisk?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(disk.mount)
                        .font(.figure(16, .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 10)
                    Text("\(Int(disk.percent))%")
                        .font(.figure(16))
                        .monospacedDigit()
                        .foregroundStyle(Palette.level(disk.percent))
                }
                Text("\(Fmt.bytes(disk.used)) of \(Fmt.bytes(disk.total)) · \(Fmt.bytes(disk.free)) free · \(disk.fstype)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                MeterBar(fraction: disk.percent / 100, tint: Palette.level(disk.percent))
                    .padding(.top, 11)

                if let smart {
                    Divider().overlay(Palette.hairline).padding(.vertical, 11)
                    if smart.available {
                        SmartRow(smart: smart)
                    } else {
                        Text("SMART unavailable · needs the sudoers rule")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

struct SmartRow: View {
    let smart: Snapshot.SmartDisk

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: smart.healthy && !smart.hasBadSectors
                      ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(smart.healthy && !smart.hasBadSectors
                                     ? Palette.good : Palette.rose)
                Text(smart.health ?? "unknown")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                if let model = smart.model {
                    Text(model)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                if let temp = smart.temp { fact("\(temp)°C", "temp") }
                if let years = smart.years { fact(String(format: "%.1fy", years), "powered") }
                fact("\(smart.reallocated ?? 0)", "realloc",
                     bad: (smart.reallocated ?? 0) > 0)
                fact("\(smart.pending ?? 0)", "pending",
                     bad: (smart.pending ?? 0) > 0)
            }
        }
    }

    private func fact(_ value: String, _ label: String, bad: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.figure(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(bad ? Palette.rose : Color.primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

struct Waiting: View {
    let state: Client.State

    var body: some View {
        VStack(spacing: 14) {
            if case .failed(let message) = state {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(Palette.warm)
                Text(message)
                    .font(.system(size: 16, weight: .semibold))
                Text("Check the address in Settings, and that the agent is running.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                Text("Waking the agent…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }
}

struct LiveBadge: View {
    @EnvironmentObject var client: Client

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(colour)
                .frame(width: 7, height: 7)
            Text(client.state.label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.card, in: .capsule)
        .overlay(Capsule().strokeBorder(Palette.hairline))
    }

    private var colour: Color {
        switch client.state {
        case .live: return Palette.accent
        case .paused: return Palette.warm
        case .failed: return Palette.rose
        default: return .secondary
        }
    }
}
