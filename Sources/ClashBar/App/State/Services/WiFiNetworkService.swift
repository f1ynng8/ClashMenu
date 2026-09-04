import CoreWLAN
import CoreLocation
import Foundation

enum WiFiSSIDResolution: Equatable {
    case connected(String)
    case notConnected
    case unavailable
}

struct WiFiNetworkService {
    func resolveCurrentSSID() -> WiFiSSIDResolution {
        let authorizationStatus = CLLocationManager().authorizationStatus
        if authorizationStatus == .denied || authorizationStatus == .restricted || authorizationStatus == .notDetermined {
            return .unavailable
        }

        let client = CWWiFiClient.shared()
        let interfaces = client.interfaces() ?? []

        for interface in interfaces {
            if let ssid = interface.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines), !ssid.isEmpty {
                return .connected(ssid)
            }
        }

        let hasActiveWiFiInterface = interfaces.contains { $0.powerOn() || $0.serviceActive() }
        if hasActiveWiFiInterface {
            return .unavailable
        }
        return .notConnected
    }
}
