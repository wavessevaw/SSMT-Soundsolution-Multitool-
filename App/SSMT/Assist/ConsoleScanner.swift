import Darwin
import Foundation
import SSMTCore

/// Finds Behringer / Midas consoles on the local network: "/xinfo" broadcast to UDP 10023 (X32 / M32) and 10024
/// (X Air / MR) on every IPv4 interface, answers collected for a moment. Blocking: call off the main thread.
enum ConsoleScanner {
    static func scan(seconds: Double = 1.5) -> [DiscoveredConsole] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = INADDR_ANY
        _ = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }

        let packet = [UInt8](ConsoleDiscovery.request.encoded())
        for address in Set(broadcastAddresses() + ["255.255.255.255"]) {
            for port: UInt16 in [10023, 10024] {
                var to = sockaddr_in()
                to.sin_family = sa_family_t(AF_INET)
                to.sin_port = port.bigEndian
                inet_pton(AF_INET, address, &to.sin_addr)
                _ = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &to) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }

        var found: [String: DiscoveredConsole] = [:]
        var buffer = [UInt8](repeating: 0, count: 2048)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length) }
                }
            }
            guard n > 0 else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            let family: MixerFamily = UInt16(bigEndian: from.sin_port) == 10024 ? .xAir : .x32
            for m in OSCMessage.decode(Data(buffer[0..<n])) ?? [] {
                if let c = ConsoleDiscovery.parse(m, sender: ip, family: family) { found[c.id] = c }
            }
        }
        return found.values.sorted { $0.ip.localizedStandardCompare($1.ip) == .orderedAscending }
    }

    /// Broadcast address of every IPv4 interface that is up (Wi-Fi, Ethernet, USB adapters).
    private static func broadcastAddresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            let flags = Int32(ifa.pointee.ifa_flags)
            if let addr = ifa.pointee.ifa_dstaddr, addr.pointee.sa_family == sa_family_t(AF_INET),
               flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var a = sin.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &a, &host, socklen_t(INET_ADDRSTRLEN))
                }
                out.append(String(cString: host))
            }
            p = ifa.pointee.ifa_next
        }
        return out
    }
}
