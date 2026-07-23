import Foundation
import insulationC

class IPowerHepler {
  private init() {}

  static let shared = IPowerHepler();

  private(set) var plistObj: [String: Any] = [:];
  var commonProductObject: CommonProduct? = nil;

  func getCPUMaxPower() -> Int {
    if self.plistObj.isEmpty {
      self.getLocalPrefValue();
    }
    let powerValue = (self.plistObj["cpuMinPowerValue"] as? String) ?? "";
    let num = Int(powerValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0;
    return num;
  }

  // 获取本地配置文件内容
  func getLocalPrefValue() {
    let plistValue = IFileManager.getPlistContent(
      withPath: insulationC.rootlessPath("/var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist")
    );
    self.plistObj = plistValue;
  }

  // 模拟电池温度控制cpu频率
  func executePuppetEvent() {
    self.getLocalPrefValue();
    let eventType = (self.plistObj["thermalPuppetValue"] as? String) ?? "";
    if let direction = ThermalLevelEnum(rawValue: eventType) {
      direction.next();
    }
  }
}
