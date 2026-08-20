import SwiftUI

struct ContainersScreen: View {
    @EnvironmentObject var client: Client
    @State private var query = ""

    private var containers: [Snapshot.Container] {
        let all = client.snapshot?.containers ?? []
        guard !query.isEmpty else { return all }
        let needle = query.lowercased()
        return all.filter {
            $0.name.lowercased().contains(needle) || $0.image.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if client.snapshot == nil {
                    Waiting(state: client.state).padding(.top, 90)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(containers) { container in
                            ContainerRow(container: container)
                        }
                        if containers.isEmpty {
                            Text("Nothing matches “\(query)”")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .refreshable { await client.refreshOnce() }
            .searchable(text: $query, prompt: "Name or image")
            .navigationTitle("Containers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let snapshot = client.snapshot {
                        Text("\(snapshot.runningCount)/\(snapshot.containers.count)")
                            .font(.figure(13, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct ContainerRow: View {
    let container: Snapshot.Container

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(container.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let chip {
                        Text(chip.0)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.raised, in: .capsule)
                            .foregroundStyle(chip.1)
                    }
                }
                Text(container.image)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(container.status)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if container.running {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "%.1f%%", container.cpu))
                        .font(.figure(13, .semibold))
                        .monospacedDigit()
                    Text(Fmt.bytes(container.mem))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Palette.card, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline))
    }

    private var tint: Color {
        switch container.condition {
        case .healthy: return Palette.good
        case .unhealthy: return Palette.rose
        case .restarting, .starting: return Palette.warm
        case .running: return Palette.accent
        case .stopped: return .secondary.opacity(0.5)
        }
    }

    private var chip: (String, Color)? {
        switch container.condition {
        case .unhealthy: return ("unhealthy", Palette.rose)
        case .starting: return ("starting", Palette.warm)
        case .restarting: return ("restarting", Palette.warm)
        case .stopped: return (container.state, .secondary)
        default: return nil
        }
    }
}
