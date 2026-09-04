import CoreLocation
import Foundation

@MainActor
extension AppState {
    func requestLocationPermissionIfNeeded() {
        self.locationPermissionService.requestIfNeeded { [weak self] status in
            guard let self else { return }
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                self.appendLog(
                    level: "info",
                    message: self.local(
                        "位置服务权限已授权，Wi‑Fi SSID 自动识别可用。",
                        "Location permission granted. Wi-Fi SSID auto-detection is available."))
                self.scheduleSceneEvaluationIfNeeded(force: true)
            case .denied, .restricted:
                self.appendLog(
                    level: "warning",
                    message: self.local(
                        "位置服务权限未开启，无法读取 Wi‑Fi SSID。请在系统设置中允许 ClashMenu 使用定位。",
                        "Location permission is unavailable. ClashMenu cannot read Wi-Fi SSID until Location Services is allowed in System Settings."))
            case .notDetermined:
                self.appendLog(
                    level: "info",
                    message: self.local(
                        "正在请求位置服务权限，用于识别当前 Wi‑Fi SSID。",
                        "Requesting location permission to detect the current Wi-Fi SSID."))
            @unknown default:
                break
            }
        }
    }
}
