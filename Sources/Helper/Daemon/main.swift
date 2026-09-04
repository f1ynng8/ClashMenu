import Foundation
import ProxyHelperShared
import Security
import SystemConfiguration

private enum ProxyHelperError: LocalizedError {
    case invalidHost
    case invalidPort
    case invalidDNSAddress
    case missingPreferences
    case missingCurrentSet
    case noEnabledNetworkServices
    case systemConfigurationFailure(action: String, code: Int32, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Invalid proxy host"
        case .invalidPort:
            "Invalid proxy port"
        case .invalidDNSAddress:
            "Invalid DNS server address"
        case .missingPreferences:
            "Unable to access system network preferences"
        case .missingCurrentSet:
            "Unable to find current network set"
        case .noEnabledNetworkServices:
            "No enabled network services found"
        case let .systemConfigurationFailure(action, _, detail):
            "\(action) failed: \(detail)"
        }
    }
}

private final class SystemProxyConfigurator {
    private struct ProxyEntrySpec {
        let enableKey: String
        let hostKey: String
        let portKey: String
    }

    private static let proxyEntrySpecs: [ProxyEntrySpec] = [
        ProxyEntrySpec(
            enableKey: kSCPropNetProxiesHTTPEnable as String,
            hostKey: kSCPropNetProxiesHTTPProxy as String,
            portKey: kSCPropNetProxiesHTTPPort as String),
        ProxyEntrySpec(
            enableKey: kSCPropNetProxiesHTTPSEnable as String,
            hostKey: kSCPropNetProxiesHTTPSProxy as String,
            portKey: kSCPropNetProxiesHTTPSPort as String),
        ProxyEntrySpec(
            enableKey: kSCPropNetProxiesSOCKSEnable as String,
            hostKey: kSCPropNetProxiesSOCKSProxy as String,
            portKey: kSCPropNetProxiesSOCKSPort as String),
    ]
    private let exceptionsListKey = kSCPropNetProxiesExceptionsList as String
    private let dnsServerAddressesKey = kSCPropNetDNSServerAddresses as String

    func setSystemProxy(
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        bypassHosts: [String]) throws
    {
        try self.validate(host: host)
        let ports = try validatedPorts(
            httpPort: httpPort,
            httpsPort: httpsPort,
            socksPort: socksPort,
            requiresEnabledProxy: true)
        let normalizedBypassHosts = self.normalizedBypassHosts(bypassHosts)

        try withMutableProxyProtocols { protocols in
            for proxyProtocol in protocols {
                var config = self.configuration(for: proxyProtocol)
                let portValues = [ports.httpPort, ports.httpsPort, ports.socksPort]
                for (spec, portValue) in zip(Self.proxyEntrySpecs, portValues) {
                    self.configureProxyEntry(
                        config: &config,
                        spec: spec,
                        host: host,
                        port: portValue)
                }
                config[self.exceptionsListKey] = normalizedBypassHosts

                guard SCNetworkProtocolSetConfiguration(proxyProtocol, config as CFDictionary) else {
                    throw self.systemConfigurationError(action: "Set proxy configuration")
                }
            }
        }
    }

    func clearSystemProxy() throws {
        try self.withMutableProxyProtocols { protocols in
            for proxyProtocol in protocols {
                var config = self.configuration(for: proxyProtocol)
                for spec in Self.proxyEntrySpecs {
                    self.configureProxyEntry(config: &config, spec: spec, host: "", port: 0)
                }
                config[self.exceptionsListKey] = []

                guard SCNetworkProtocolSetConfiguration(proxyProtocol, config as CFDictionary) else {
                    throw self.systemConfigurationError(action: "Clear proxy configuration")
                }
            }
        }
    }

    func setSystemDNS(serverAddresses: [String]) throws {
        let normalizedServers = try self.normalizedDNSServerAddresses(serverAddresses)

        try self.withMutableDNSProtocols { protocols in
            for dnsProtocol in protocols {
                var config = self.configuration(for: dnsProtocol)
                config[self.dnsServerAddressesKey] = normalizedServers

                guard SCNetworkProtocolSetConfiguration(dnsProtocol, config as CFDictionary) else {
                    throw self.systemConfigurationError(action: "Set DNS configuration")
                }
            }
        }
    }

    func clearSystemDNS() throws {
        try self.withMutableDNSProtocols { protocols in
            for dnsProtocol in protocols {
                var config = self.configuration(for: dnsProtocol)
                config.removeValue(forKey: self.dnsServerAddressesKey)

                guard SCNetworkProtocolSetConfiguration(dnsProtocol, config as CFDictionary) else {
                    throw self.systemConfigurationError(action: "Clear DNS configuration")
                }
            }
        }
    }

    func isSystemProxyEnabled() throws -> Bool {
        let preferences = try makePreferences()
        let protocols = try proxyProtocols(from: preferences)

        for proxyProtocol in protocols {
            let config = self.configuration(for: proxyProtocol)
            if Self.proxyEntrySpecs.contains(where: { isEnabled(config: config, key: $0.enableKey) }) {
                return true
            }
        }

        return false
    }

    func isSystemProxyConfigured(
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        bypassHosts: [String]) throws -> Bool
    {
        try self.validate(host: host)
        let ports = try validatedPorts(
            httpPort: httpPort,
            httpsPort: httpsPort,
            socksPort: socksPort,
            requiresEnabledProxy: true)
        let normalizedBypassHosts = self.normalizedBypassHosts(bypassHosts)

        let preferences = try makePreferences()
        let protocols = try proxyProtocols(from: preferences)
        let expectedPorts = [ports.httpPort, ports.httpsPort, ports.socksPort]

        for proxyProtocol in protocols {
            let config = self.configuration(for: proxyProtocol)
            guard self.bypassHostsMatchExpectedState(config: config, expectedBypassHosts: normalizedBypassHosts) else {
                return false
            }
            for (spec, expectedPort) in zip(Self.proxyEntrySpecs, expectedPorts) {
                guard self.proxyMatchesExpectedState(
                    config: config,
                    spec: spec,
                    expectedHost: host,
                    expectedPort: expectedPort)
                else {
                    return false
                }
            }
        }

        return true
    }

    private func validate(host: String) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw ProxyHelperError.invalidHost
        }
    }

    private func validatedPorts(
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        requiresEnabledProxy: Bool) throws -> (httpPort: Int, httpsPort: Int, socksPort: Int)
    {
        let httpPort = try validatedPort(httpPort)
        let httpsPort = try validatedPort(httpsPort)
        let socksPort = try validatedPort(socksPort)

        if requiresEnabledProxy, httpPort == 0, httpsPort == 0, socksPort == 0 {
            throw ProxyHelperError.invalidPort
        }

        return (httpPort: httpPort, httpsPort: httpsPort, socksPort: socksPort)
    }

    private func validatedPort(_ value: Int) throws -> Int {
        guard (0...65535).contains(value) else {
            throw ProxyHelperError.invalidPort
        }
        return value
    }

    private func configureProxyEntry(
        config: inout [String: Any],
        spec: ProxyEntrySpec,
        host: String,
        port: Int)
    {
        if port > 0 {
            config[spec.enableKey] = 1
            config[spec.hostKey] = host
            config[spec.portKey] = port
        } else {
            config[spec.enableKey] = 0
            config[spec.hostKey] = ""
            config[spec.portKey] = 0
        }
    }

    private func withMutableProxyProtocols(_ update: ([SCNetworkProtocol]) throws -> Void) throws {
        let preferences = try makePreferences()

        guard SCPreferencesLock(preferences, true) else {
            throw self.systemConfigurationError(action: "Lock system preferences")
        }
        defer { SCPreferencesUnlock(preferences) }

        let protocols = try proxyProtocols(from: preferences)
        try update(protocols)

        guard SCPreferencesCommitChanges(preferences) else {
            throw self.systemConfigurationError(action: "Commit proxy preferences")
        }
        guard SCPreferencesApplyChanges(preferences) else {
            throw self.systemConfigurationError(action: "Apply proxy preferences")
        }
    }

    private func withMutableDNSProtocols(_ update: ([SCNetworkProtocol]) throws -> Void) throws {
        let preferences = try makePreferences()

        guard SCPreferencesLock(preferences, true) else {
            throw self.systemConfigurationError(action: "Lock system preferences")
        }
        defer { SCPreferencesUnlock(preferences) }

        let protocols = try self.dnsProtocols(from: preferences)
        try update(protocols)

        guard SCPreferencesCommitChanges(preferences) else {
            throw self.systemConfigurationError(action: "Commit DNS preferences")
        }
        guard SCPreferencesApplyChanges(preferences) else {
            throw self.systemConfigurationError(action: "Apply DNS preferences")
        }
    }

    private func makePreferences() throws -> SCPreferences {
        guard let preferences = SCPreferencesCreate(nil, "com.clashmenu.helper" as CFString, nil) else {
            throw ProxyHelperError.missingPreferences
        }
        return preferences
    }

    private func proxyProtocols(from preferences: SCPreferences) throws -> [SCNetworkProtocol] {
        guard let currentSet = SCNetworkSetCopyCurrent(preferences) else {
            throw ProxyHelperError.missingCurrentSet
        }

        guard let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService] else {
            throw ProxyHelperError.noEnabledNetworkServices
        }

        let protocols = services.compactMap { service -> SCNetworkProtocol? in
            guard SCNetworkServiceGetEnabled(service) else {
                return nil
            }
            return SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
        }

        guard !protocols.isEmpty else {
            throw ProxyHelperError.noEnabledNetworkServices
        }

        return protocols
    }

    private func dnsProtocols(from preferences: SCPreferences) throws -> [SCNetworkProtocol] {
        guard let currentSet = SCNetworkSetCopyCurrent(preferences) else {
            throw ProxyHelperError.missingCurrentSet
        }

        guard let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService] else {
            throw ProxyHelperError.noEnabledNetworkServices
        }

        let protocols = services.compactMap { service -> SCNetworkProtocol? in
            guard SCNetworkServiceGetEnabled(service) else {
                return nil
            }
            return SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
        }

        guard !protocols.isEmpty else {
            throw ProxyHelperError.noEnabledNetworkServices
        }

        return protocols
    }

    private func configuration(for proxyProtocol: SCNetworkProtocol) -> [String: Any] {
        (SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any]) ?? [:]
    }

    private func isEnabled(config: [String: Any], key: String) -> Bool {
        if let value = config[key] as? NSNumber {
            return value.intValue != 0
        }
        if let value = config[key] as? Int {
            return value != 0
        }
        if let value = config[key] as? Bool {
            return value
        }
        return false
    }

    private func proxyHostAndPortMatch(
        config: [String: Any],
        spec: ProxyEntrySpec,
        expectedHost: String,
        expectedPort: Int) -> Bool
    {
        let currentHost = (config[spec.hostKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let normalizedExpectedHost = expectedHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard currentHost == normalizedExpectedHost else {
            return false
        }

        return self.intValue(config[spec.portKey]) == expectedPort
    }

    private func proxyMatchesExpectedState(
        config: [String: Any],
        spec: ProxyEntrySpec,
        expectedHost: String,
        expectedPort: Int) -> Bool
    {
        let enabled = self.isEnabled(config: config, key: spec.enableKey)
        if expectedPort == 0 {
            return !enabled
        }
        guard enabled else {
            return false
        }
        return self.proxyHostAndPortMatch(
            config: config,
            spec: spec,
            expectedHost: expectedHost,
            expectedPort: expectedPort)
    }

    private func normalizedBypassHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func normalizedDNSServerAddresses(_ addresses: [String]) throws -> [String] {
        var seen = Set<String>()
        let normalized = addresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalized.isEmpty else {
            throw ProxyHelperError.invalidDNSAddress
        }

        for address in normalized {
            guard self.isValidIPAddress(address) else {
                throw ProxyHelperError.invalidDNSAddress
            }
        }

        return normalized.filter { seen.insert($0.lowercased()).inserted }
    }

    private func isValidIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }

        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private func bypassHostsMatchExpectedState(config: [String: Any], expectedBypassHosts: [String]) -> Bool {
        let currentHosts = self.normalizedBypassHosts(config[self.exceptionsListKey] as? [String] ?? [])
        return currentHosts.map { $0.lowercased() } == expectedBypassHosts.map { $0.lowercased() }
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func systemConfigurationError(action: String) -> ProxyHelperError {
        let code = SCError()
        let detail = String(cString: SCErrorString(code))
        return .systemConfigurationFailure(action: action, code: code, detail: detail)
    }
}

private final class ProxyHelperService: NSObject, ProxyHelperProtocol {
    private let configurator = SystemProxyConfigurator()

    func setSystemProxy(
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        bypassHosts: [String],
        completion: @escaping (Bool, String?) -> Void)
    {
        do {
            try self.configurator.setSystemProxy(
                host: host,
                httpPort: httpPort,
                httpsPort: httpsPort,
                socksPort: socksPort,
                bypassHosts: bypassHosts)
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    func clearSystemProxy(completion: @escaping (Bool, String?) -> Void) {
        do {
            try self.configurator.clearSystemProxy()
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    func setSystemDNS(serverAddresses: [String], completion: @escaping (Bool, String?) -> Void) {
        do {
            try self.configurator.setSystemDNS(serverAddresses: serverAddresses)
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    func clearSystemDNS(completion: @escaping (Bool, String?) -> Void) {
        do {
            try self.configurator.clearSystemDNS()
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    func getSystemProxyState(completion: @escaping (Bool, Bool, String?) -> Void) {
        do {
            let enabled = try configurator.isSystemProxyEnabled()
            completion(true, enabled, nil)
        } catch {
            completion(false, false, error.localizedDescription)
        }
    }

    func isSystemProxyConfigured(
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        bypassHosts: [String],
        completion: @escaping (Bool, Bool, String?) -> Void)
    {
        do {
            let configured = try configurator.isSystemProxyConfigured(
                host: host,
                httpPort: httpPort,
                httpsPort: httpsPort,
                socksPort: socksPort,
                bypassHosts: bypassHosts)
            completion(true, configured, nil)
        } catch {
            completion(false, false, error.localizedDescription)
        }
    }
}

private struct SigningIdentity {
    let identifier: String
    let teamIdentifier: String?
}

private final class XPCClientValidator {
    private lazy var helperIdentity: SigningIdentity? = signingIdentityForCurrentProcess()

    func isValid(connection: NSXPCConnection) -> Bool {
        guard let clientIdentity = signingIdentity(for: connection.processIdentifier) else {
            return false
        }

        guard clientIdentity.identifier == ProxyHelperConstants.allowedClientBundleIdentifier else {
            return false
        }

        guard let helperIdentity else {
            return false
        }

        if let helperTeamIdentifier = helperIdentity.teamIdentifier,
           let clientTeamIdentifier = clientIdentity.teamIdentifier
        {
            return helperTeamIdentifier == clientTeamIdentifier
        }

        // Ad-hoc/local builds do not provide Team ID. Keep identifier-based checks active
        // and rely on launchd registration + code signing requirement gate.
        return true
    }

    private func signingIdentityForCurrentProcess() -> SigningIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return nil
        }
        return self.signingIdentity(for: code)
    }

    private func signingIdentity(for pid: pid_t) -> SigningIdentity? {
        let attributes: [String: Any] = [kSecGuestAttributePid as String: pid]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &code) == errSecSuccess,
              let code
        else {
            return nil
        }
        return self.signingIdentity(for: code)
    }

    private func signingIdentity(for code: SecCode) -> SigningIdentity? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        return self.signingIdentity(for: staticCode)
    }

    private func signingIdentity(for staticCode: SecStaticCode) -> SigningIdentity? {
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation) == errSecSuccess,
            let signingInformation = signingInformation as? [String: Any],
            let identifier = signingInformation[kSecCodeInfoIdentifier as String] as? String
        else {
            return nil
        }

        let teamIdentifier = signingInformation[kSecCodeInfoTeamIdentifier as String] as? String
        return SigningIdentity(identifier: identifier, teamIdentifier: teamIdentifier)
    }
}

private final class ProxyHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = ProxyHelperService()
    private let validator = XPCClientValidator()
    private let allowedBypassHostClasses = NSSet(array: [NSArray.self, NSString.self]) as? Set<AnyHashable> ?? []
    private let allowedDNSServerClasses = NSSet(array: [NSArray.self, NSString.self]) as? Set<AnyHashable> ?? []

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard self.validator.isValid(connection: newConnection) else {
            return false
        }
        newConnection.exportedInterface = self.makeExportedInterface()
        newConnection.exportedObject = self.service
        newConnection.resume()
        return true
    }

    private func makeExportedInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: ProxyHelperProtocol.self)
        interface.setClasses(
            self.allowedBypassHostClasses,
            for: #selector(ProxyHelperProtocol.setSystemProxy(
                host:httpPort:httpsPort:socksPort:bypassHosts:completion:)),
            argumentIndex: 4,
            ofReply: false)
        interface.setClasses(
            self.allowedBypassHostClasses,
            for: #selector(ProxyHelperProtocol.isSystemProxyConfigured(
                host:httpPort:httpsPort:socksPort:bypassHosts:completion:)),
            argumentIndex: 4,
            ofReply: false)
        interface.setClasses(
            self.allowedDNSServerClasses,
            for: #selector(ProxyHelperProtocol.setSystemDNS(serverAddresses:completion:)),
            argumentIndex: 0,
            ofReply: false)
        return interface
    }
}

@main
private struct ClashMenuProxyHelperMain {
    static func main() {
        let delegate = ProxyHelperListenerDelegate()
        let listener = NSXPCListener(machServiceName: ProxyHelperConstants.machServiceName)
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(ProxyHelperConstants.allowedClientRequirement)
        listener.resume()
        dispatchMain()
    }
}
