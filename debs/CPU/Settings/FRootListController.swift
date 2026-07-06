import Foundation
import Preferences
import UIKit

@objc(FRootListController)
public final class FRootListController: PSListController {
    private var prefPath: String { CPUthermalShared.currentPrefPath }
    private var legacyPrefPath: String? { CPUthermalShared.legacyPrefPaths.first }

    private func ensurePrefsDirectory() {
        CPUthermalShared.ensurePrefDirectory()
    }

    private func migrateLegacyPrefsIfNeeded() {
        _ = CPUthermalShared.readPrefs()
    }

    private func prefs() -> NSMutableDictionary {
        CPUthermalShared.readMutablePrefs()
    }

    private func savePrefs(_ prefs: NSMutableDictionary) {
        CPUthermalShared.writePrefs(prefs)
        notify_post(CPUthermalShared.settingsChangedNotification)
    }

    private func powerModeValue() -> String {
        prefs()["powerMode"] as? String ?? "fullPower"
    }

    private func powerModeTitle(_ mode: String) -> String {
        mode == "lowPower" ? "低功耗" : "防温控"
    }

    private func powerModeLabel() -> String {
        "功率模式：\(powerModeTitle(powerModeValue()))"
    }

    private func restartThermalmonitord() {
        CPUthermalShared.restartThermalmonitordSoon()
    }

    private func savePowerMode(_ mode: String?) {
        let prefs = self.prefs()
        prefs["powerMode"] = mode ?? "fullPower"
        savePrefs(prefs)
        notify_post(CPUthermalShared.powerModeChangedNotification)
        restartThermalmonitord()

        if let specifier = specifier(forID: "powerMode") {
            specifier.name = powerModeLabel()
        }
        reloadSpecifierID("powerMode", animated: true)
    }

    @objc public override func setPreferenceValue(_ value: Any?, specifier spec: PSSpecifier!) {
        guard let key = spec.property(forKey: "key") as? String else { return }
        let prefs = self.prefs()
        prefs[key] = value
        savePrefs(prefs)
    }

    @objc public override func readPreferenceValue(_ spec: PSSpecifier!) -> Any? {
        guard let key = spec.property(forKey: "key") as? String else { return nil }
        if let value = prefs()[key] {
            return value
        }
        if key == "keepCPMSAlive" {
            return true
        }
        if key == "suppressThermalNotifications" {
            return false
        }
        return true
    }

    @objc public func readPowerModeValue(_ spec: PSSpecifier) -> Any {
        powerModeLabel()
    }

    @objc public func openPowerModePicker() {
        showPowerModePicker()
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let index = index(for: indexPath)
        if index >= 0, index < specifiers.count,
           let specifier = specifiers[index] as? PSSpecifier,
           (specifier.property(forKey: "key") as? String) == "powerMode" {
            tableView.deselectRow(at: indexPath, animated: true)
            showPowerModePicker()
            return
        }
        super.tableView(tableView, didSelectRowAt: indexPath)
    }

    private func showPowerModePicker() {
        let alert = UIAlertController(
            title: "功率模式",
            message: "低功耗 = 限制 CPU 最高 2016MHz，不抬高待机频率\n防温控 = 减少降频/降亮度，保留系统安全保护",
            preferredStyle: .actionSheet
        )

        let currentMode = powerModeValue()
        let low = UIAlertAction(title: "低功耗", style: .default) { [weak self] _ in
            self?.savePowerMode("lowPower")
        }
        let full = UIAlertAction(title: "防温控", style: .default) { [weak self] _ in
            self?.savePowerMode("fullPower")
        }
        if currentMode == "lowPower" {
            low.setValue(true, forKey: "checked")
        } else {
            full.setValue(true, forKey: "checked")
        }

        alert.addAction(low)
        alert.addAction(full)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    private func openURLString(_ urlString: String, fallback: String?, failureMessage: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            guard !success else { return }
            if let fallback, let fallbackURL = URL(string: fallback) {
                UIApplication.shared.open(fallbackURL, options: [:])
                return
            }
            if let failureMessage {
                self?.showSimpleAlert(title: "提示", message: failureMessage)
            }
        }
    }

    private func showSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }

    @objc public func openQQFeedbackGroup() {
        openURLString("https://qm.qq.com/q/JvllAQiEwI", fallback: nil)
    }

    @objc public func openAlipayDonate() {
        openURLString(
            "alipays://platformapi/startapp?appId=20000067&url=https%3A%2F%2Fqr.alipay.com%2Ffkx16683ylwdrfdo8fiuy01",
            fallback: "https://qr.alipay.com/fkx16683ylwdrfdo8fiuy01"
        )
    }

    @objc public func openRepo() {
        openURLString("sileo://source/https://huayuarc.github.io", fallback: "https://huayuarc.github.io")
    }

    @objc public func usreboot() {
        let alert = UIAlertController(
            title: "重启用户空间",
            message: "重启 SpringBoard 和所有用户态进程？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定重启", style: .destructive) { _ in
            if let toolPath = CPUthermalShared.toolPath,
               FileManager.default.isExecutableFile(atPath: toolPath),
               CPUthermalShared.runAndWait(path: toolPath, arguments: ["CPUthermalTool", "userspace-reboot"]) {
                return
            }
            _ = CPUthermalShared.runAndWait(path: CPUthermalShared.launchctlPath, arguments: ["launchctl", "reboot", "userspace"])
        })
        present(alert, animated: true)
    }

    private func switchSpecifier(label: String, key: String) -> PSSpecifier {
        let spec = PSSpecifier.preferenceSpecifierNamed(
            label,
            target: self,
            set: #selector(setPreferenceValue(_:specifier:)),
            get: #selector(readPreferenceValue(_:)),
            detail: nil,
            cell: .switchCell,
            edit: nil
        )
        spec?.identifier = key
        spec?.setProperty(key, forKey: "key")
        return spec!
    }

    private func powerModeSpecifier() -> PSSpecifier {
        let spec = PSSpecifier.preferenceSpecifierNamed(
            powerModeLabel(),
            target: self,
            set: nil,
            get: nil,
            detail: nil,
            cell: .buttonCell,
            edit: nil
        )
        spec?.identifier = "powerMode"
        spec?.setProperty("powerMode", forKey: "key")
        spec?.buttonAction = #selector(openPowerModePicker)
        return spec!
    }

    private func buttonSpecifier(label: String, action: Selector, identifier: String) -> PSSpecifier {
        let spec = PSSpecifier.preferenceSpecifierNamed(
            label,
            target: self,
            set: nil,
            get: nil,
            detail: nil,
            cell: .buttonCell,
            edit: nil
        )
        spec?.buttonAction = action
        spec?.identifier = identifier
        return spec!
    }

    public override var specifiers: NSMutableArray! {
        get {
            if let cached = value(forKey: "_specifiers") as? NSMutableArray {
                return cached
            }

            let specs = NSMutableArray()
            var group: PSSpecifier

            group = PSSpecifier.emptyGroup()!
            group.setProperty("CPUthermal", forKey: "label")
            specs.add(group)
            specs.add(switchSpecifier(label: "启用 CPUthermal", key: "enabled"))

            group = PSSpecifier.emptyGroup()!
            group.setProperty("功率模式", forKey: "label")
            group.setProperty("低功耗只限制最高频率，不再强制锁 2016MHz；防温控会减少降频/降亮度，但保留系统过热保护。", forKey: "footerText")
            specs.add(group)
            specs.add(powerModeSpecifier())

            group = PSSpecifier.emptyGroup()!
            group.setProperty("核心保护", forKey: "label")
            group.setProperty("建议保持默认：CPU/亮度保护开启，避免误判温度。", forKey: "footerText")
            specs.add(group)
            specs.add(switchSpecifier(label: "CPU 性能保护", key: "cpuProtection"))
            specs.add(switchSpecifier(label: "屏幕亮度保护", key: "brightnessProtection"))
            specs.add(switchSpecifier(label: "屏蔽高温通知", key: "suppressThermalNotifications"))

            group = PSSpecifier.emptyGroup()!
            group.setProperty("高级", forKey: "label")
            group.setProperty("强烈建议开启：温度超过 70°C 或读温失败时放行系统温控，防止异常发热和自动黑屏。", forKey: "footerText")
            specs.add(group)
            specs.add(switchSpecifier(label: "保留 CPMS 紧急保护", key: "keepCPMSAlive"))

            group = PSSpecifier.emptyGroup()!
            group.setProperty("操作", forKey: "label")
            specs.add(group)
            specs.add(buttonSpecifier(label: "重启用户空间", action: #selector(usreboot), identifier: "usreboot"))

            group = PSSpecifier.emptyGroup()!
            group.setProperty("关于我 / 投喂", forKey: "label")
            specs.add(group)
            specs.add(buttonSpecifier(label: "📮 QQ 交流反馈群", action: #selector(openQQFeedbackGroup), identifier: "qqGroup"))
            specs.add(buttonSpecifier(label: "💰 支付宝🧧打赏", action: #selector(openAlipayDonate), identifier: "alipayDonate"))
            specs.add(buttonSpecifier(label: "📦 Sileo 添加源", action: #selector(openRepo), identifier: "sileoRepo"))

            self.specifiers = specs
            return specs
        }
        set {
            super.specifiers = newValue
        }
    }
}
