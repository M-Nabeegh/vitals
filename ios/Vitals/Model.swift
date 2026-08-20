import Foundation

/// The payload the agent streams. Every field is optional-tolerant: an agent
/// running an older build, or a machine without temperature sensors, should
/// degrade a row rather than fail the whole decode.
struct Snapshot: Decodable, Equatable {
    var at: Double = 0
    var host = Host()
    var cpu = CPU()
    var memory = Memory()
    var network: [Interface] = []
    var disks: [Disk] = []
    var smart: [SmartDisk] = []
    var containers: [Container] = []
    var alerts: [Alert] = []
    var agent = AgentInfo()

    struct Host: Decodable, Equatable {
        var hostname = "server"
        var os = ""
        var kernel = ""
        var uptime: Double = 0
    }

    struct CPU: Decodable, Equatable {
        var percent: Double = 0
        var cores: [Double] = []
        var count: Int = 0
        var load: [Double] = []
        var temp: Double?
    }

    struct Memory: Decodable, Equatable {
        var total: Int64 = 0
        var used: Int64 = 0
        var available: Int64 = 0
        var percent: Double = 0
        var cached: Int64 = 0
        var swap = Swap()

        struct Swap: Decodable, Equatable {
            var total: Int64 = 0
            var used: Int64 = 0
            var percent: Double = 0
        }
    }

    struct Interface: Decodable, Equatable, Identifiable {
        var name = ""
        var rx_rate: Double = 0
        var tx_rate: Double = 0
        var id: String { name }
    }

    struct Disk: Decodable, Equatable, Identifiable {
        var device = ""
        var mount = ""
        var fstype = ""
        var total: Int64 = 0
        var used: Int64 = 0
        var free: Int64 = 0
        var percent: Double = 0
        var id: String { mount }

        /// `/dev/sda1` and `/dev/nvme0n1p2` both belong to a physical device
        /// that SMART reports under its bare name.
        var physicalDevice: String {
            var name = device.replacingOccurrences(of: "/dev/", with: "")
            while let last = name.last, last.isNumber { name.removeLast() }
            if name.hasSuffix("p") { name.removeLast() }
            return name
        }
    }

    struct SmartDisk: Decodable, Equatable, Identifiable {
        var device = ""
        var available = false
        var model: String?
        var health: String?
        var temp: Int?
        var hours: Int?
        var reallocated: Int?
        var pending: Int?
        var uncorrectable: Int?
        var rotational: Bool?
        var id: String { device }

        var healthy: Bool {
            guard let health else { return true }
            let value = health.uppercased()
            return value == "PASSED" || value == "OK"
        }

        var hasBadSectors: Bool {
            (reallocated ?? 0) > 0 || (pending ?? 0) > 0 || (uncorrectable ?? 0) > 0
        }

        var years: Double? { hours.map { Double($0) / 8_760 } }
    }

    struct Container: Decodable, Equatable, Identifiable {
        var id = ""
        var name = ""
        var image = ""
        var state = ""
        var health: String?
        var status = ""
        var cpu: Double = 0
        var mem: Int64 = 0
        var mem_limit: Int64 = 0
        var mem_percent: Double = 0

        var running: Bool { state == "running" }

        enum Condition { case healthy, unhealthy, starting, running, stopped, restarting }

        var condition: Condition {
            if state == "restarting" { return .restarting }
            if !running { return .stopped }
            switch health {
            case "healthy": return .healthy
            case "unhealthy": return .unhealthy
            case "starting": return .starting
            default: return .running
            }
        }
    }

    struct Alert: Decodable, Equatable, Identifiable {
        var level = ""
        var subject = ""
        var message = ""
        var id: String { "\(level)-\(subject)-\(message)" }
        var critical: Bool { level == "critical" }
    }

    struct AgentInfo: Decodable, Equatable {
        var viewers: Int = 0
        var samples: Int = 0
        var wakes: Int = 0
        var docker: Bool = true
    }

    var runningCount: Int { containers.filter(\.running).count }

    func smart(for disk: Disk) -> SmartDisk? {
        smart.first { $0.device == disk.physicalDevice }
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value), index = 0
        while size >= 1024, index < units.count - 1 { size /= 1024; index += 1 }
        let digits = (size < 10 && index > 0) ? 1 : 0
        return String(format: "%.\(digits)f %@", size, units[index])
    }

    /// Split so a view can style the number and its unit differently.
    static func split(_ value: Int64) -> (String, String) {
        let parts = bytes(value).split(separator: " ")
        return (String(parts.first ?? "0"), String(parts.last ?? ""))
    }

    static func rate(_ bytesPerSecond: Double) -> (String, String) {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var size = bytesPerSecond, index = 0
        while size >= 1024, index < units.count - 1 { size /= 1024; index += 1 }
        let digits = (size < 10 && index > 0) ? 1 : 0
        return (String(format: "%.\(digits)f", size), units[index])
    }

    static func uptime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let days = total / 86_400, hours = (total % 86_400) / 3_600, minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
