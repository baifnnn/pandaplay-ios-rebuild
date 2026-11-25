import Foundation

/// A Bonjour service advertisement for the wireless car channel.
///
/// The accessory registers a service type of its own invention rather than an AirPlay
/// name: the strings table has `panda.wireless-car` and no `_airplay._tcp` anywhere, and
/// three independent probes failed to find an AirPlay advertisement on the wire. A
/// controller therefore discovers this receiver by that private type.
public struct BonjourAdvertisement: Sendable {
    /// Service type without the trailing `.local`; mDNS appends that itself.
    public var serviceType: String
    /// Instance name shown to the controller.
    public var instanceName: String
    /// Port the control endpoint listens on.
    public var port: UInt16
    /// TXT entries, `key=value`.
    public var txt: [String]
    /// Host name the SRV record points at.
    public var hostName: String
    /// Address published in the A record.
    public var address: UInt32

    public init(
        serviceType: String = "panda.wireless-car",
        instanceName: String = "PandaPlay+",
        port: UInt16 = 7000,
        txt: [String] = ["ty=PandaPlay+", "ver=1.3", "proto=1", "srcvers=1.0.2"],
        hostName: String = "pandaplay",
        address: UInt32 = 0x7F00_0001
    ) {
        self.serviceType = serviceType
        self.instanceName = instanceName
        self.port = port
        self.txt = txt
        self.hostName = hostName
        self.address = address
    }

    public var serviceTypeFqdn: String { serviceType + ".local" }
    public var instanceFqdn: String { instanceName + "." + serviceTypeFqdn }
    public var hostFqdn: String { hostName + ".local" }

    /// Builds the four records a browsing controller needs.
    public func records(ttl: UInt32 = 4500) -> [DnsRecord] {
        [
            DnsRecord(name: serviceTypeFqdn, type: .ptr, ttl: ttl,
                      data: DnsWire.ptrData(target: instanceFqdn)),
            DnsRecord(name: instanceFqdn, type: .srv, ttl: ttl,
                      data: DnsWire.srvData(priority: 0, weight: 0, port: port, target: hostFqdn)),
            DnsRecord(name: instanceFqdn, type: .txt, ttl: ttl,
                      data: DnsWire.txtData(txt)),
            DnsRecord(name: hostFqdn, type: .a, ttl: ttl,
                      data: DnsWire.aData(address)),
        ]
    }

    /// Records a question asks for. A wildcard question gets everything.
    public func records(answering question: DnsQuestion, ttl: UInt32 = 4500) -> [DnsRecord] {
        let all = records(ttl: ttl)
        let name = question.name.lowercased()
        guard question.type != .any else {
            return all.filter { $0.name.lowercased() == name }
        }
        return all.filter { $0.name.lowercased() == name && $0.type == question.type }
    }
}

/// Turns one question into a reply packet, or nil when nothing matches.
///
/// This is the whole responder policy: answer only what is asked, never volunteer, and
/// treat the goodbye as an ordinary reply with a zero TTL so a caching controller drops
/// the entry instead of dialling a closed port.
public enum BonjourResponder {
    public static func respond(
        to query: Data,
        advertisement: BonjourAdvertisement,
        ttl: UInt32 = 4500
    ) -> Data? {
        guard let parsed = DnsWire.parseQuery(query) else { return nil }
        var answers: [DnsRecord] = []
        for question in parsed.questions {
            answers.append(contentsOf: advertisement.records(answering: question, ttl: ttl))
        }
        guard !answers.isEmpty else { return nil }
        return DnsWire.encodeResponse(id: parsed.id, questions: parsed.questions, answers: answers)
    }

    /// The withdrawal packet: same answers, zero TTL.
    public static func goodbye(advertisement: BonjourAdvertisement) -> Data {
        DnsWire.encodeResponse(
            id: 0,
            questions: [],
            answers: advertisement.records(ttl: 0)
        )
    }

    /// The unsolicited announcement sent at startup, so a controller that is already
    /// browsing does not have to poll before it can see the receiver.
    public static func announcement(advertisement: BonjourAdvertisement, ttl: UInt32 = 4500) -> Data {
        DnsWire.encodeResponse(
            id: 0,
            questions: [],
            answers: advertisement.records(ttl: ttl)
        )
    }
}
