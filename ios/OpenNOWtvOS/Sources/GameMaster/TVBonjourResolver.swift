import Darwin
import Foundation
import dnssd

/// Resolves a Bonjour service to an IPv4 address and port with DNS-SD, blocking for at most
/// `timeout`. Android TVs announce a generic host name ("Android.local") that the system resolver
/// (getaddrinfo) does not always answer, so the address is asked for over mDNS directly.
enum TVBonjourResolver {
    static func resolve(name: String, type: String, domain: String, timeout: TimeInterval) -> (String, UInt16)? {
        let deadline = Date().addingTimeInterval(timeout)
        guard let (host, port, interface) = target(name: name, type: type, domain: domain, until: deadline),
              let address = ipv4(host: host, interface: interface, until: deadline) else { return nil }
        return (address, port)
    }

    private final class Box<Value> { var value: Value? }

    private static func target(name: String, type: String, domain: String,
                               until deadline: Date) -> (String, UInt16, UInt32)? {
        let box = Box<(String, UInt16, UInt32)>()
        let callback: DNSServiceResolveReply = { _, _, interface, error, _, host, port, _, _, context in
            guard error == kDNSServiceErr_NoError, let host, let context else { return }
            Unmanaged<Box<(String, UInt16, UInt32)>>.fromOpaque(context).takeUnretainedValue().value =
                (String(cString: host), UInt16(bigEndian: port), interface)
        }
        var reference: DNSServiceRef?
        guard DNSServiceResolve(&reference, 0, 0, name, type, domain, callback,
                                Unmanaged.passUnretained(box).toOpaque()) == kDNSServiceErr_NoError,
              let reference else { return nil }
        return process(reference, box, until: deadline)
    }

    private static func ipv4(host: String, interface: UInt32, until deadline: Date) -> String? {
        let box = Box<String>()
        let callback: DNSServiceGetAddrInfoReply = { _, _, _, error, _, address, _, context in
            guard error == kDNSServiceErr_NoError, let address, address.pointee.sa_family == sa_family_t(AF_INET),
                  let context else { return }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4 in
                var bytes = ipv4.pointee.sin_addr
                _ = inet_ntop(AF_INET, &bytes, &text, socklen_t(text.count))
            }
            Unmanaged<Box<String>>.fromOpaque(context).takeUnretainedValue().value = String(cString: text)
        }
        var reference: DNSServiceRef?
        guard DNSServiceGetAddrInfo(&reference, 0, interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host,
                                    callback, Unmanaged.passUnretained(box).toOpaque()) == kDNSServiceErr_NoError,
              let reference else { return nil }
        return process(reference, box, until: deadline)
    }

    /// Feeds DNS-SD replies to the callback until it has filled `box` or time runs out.
    private static func process<Value>(_ reference: DNSServiceRef, _ box: Box<Value>, until deadline: Date) -> Value? {
        defer { DNSServiceRefDeallocate(reference) }
        while box.value == nil, deadline.timeIntervalSinceNow > 0 {
            var poller = pollfd(fd: DNSServiceRefSockFD(reference), events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(deadline.timeIntervalSinceNow * 1000)) == 1,
                  DNSServiceProcessResult(reference) == kDNSServiceErr_NoError else { break }
        }
        return withExtendedLifetime(box) { box.value }
    }
}
