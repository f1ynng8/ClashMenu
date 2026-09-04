import Foundation

public enum ProxyHelperConstants {
    public static let machServiceName = "com.clashmenu.helper"
    public static let daemonPlistName = "com.clashmenu.helper.plist"
    public static let helperBundleProgram = "Contents/Library/HelperTools/com.clashmenu.helper"
    public static let allowedClientBundleIdentifier = "com.clashmenu"
    public static let allowedClientRequirement = "identifier \"\(allowedClientBundleIdentifier)\""
}

@objc(ProxyHelperProtocol)
public protocol ProxyHelperProtocol {
    func setSystemProxy(
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        bypassHosts: [String],
        completion: @escaping (Bool, String?) -> Void)
    func clearSystemProxy(completion: @escaping (Bool, String?) -> Void)
    func setSystemDNS(serverAddresses: [String], completion: @escaping (Bool, String?) -> Void)
    func clearSystemDNS(completion: @escaping (Bool, String?) -> Void)
    func getSystemProxyState(completion: @escaping (Bool, Bool, String?) -> Void)
    func isSystemProxyConfigured(
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        bypassHosts: [String],
        completion: @escaping (Bool, Bool, String?) -> Void)
}
