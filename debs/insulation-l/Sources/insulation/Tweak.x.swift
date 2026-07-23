import Orion
import insulationC

class CommonProductClassHook: ClassHook<CommonProduct> {
  func initProduct(_ arg: Any?) -> CommonProduct? {
    // return nil;
    let res = orig.initProduct(arg);
    IPowerHepler.shared.commonProductObject = target;
    target.putDevice(inThermalSimulationMode: "nominal");
    return res;
  }

  // func putDeviceInThermalSimulationMode(_ arg: Any?) {
  //   orig.putDeviceInThermalSimulationMode("nominal");
  // }

  // func putDeviceInLowTempSimulationMode(_ arg: Any?) {
  //   orig.putDeviceInLowTempSimulationMode("nominal");
  // }

  func tryTakeAction() {}
  func simulateLightThermalPressure() {}
  func updatePowerzoneTelemetry() {}
}

class HidSensorsHook: ClassHook<HidSensors> {
  func handleTemperatureEvent(_ arg1: Int, service arg2: Any?) {}
}

class NSDictionaryHook: ClassHook<NSDictionary> {
  class func dictionaryWithContentsOfFile(_ path: String) -> Any? {
    let res = orig.dictionaryWithContentsOfFile(path);
    if path.contains("/System/Library/ThermalMonitor/") {
      if let origObj = res as? [String: Any] {
        let obj = IDictHepler.shared.patchThermalPlist(origObj as CFDictionary);
        return obj;
      }
    }
    return res;
  }
}

class InsulationTInit: Tweak {
  required init() {
    let center = CFNotificationCenterGetDarwinNotifyCenter();
    let executePuppetEventName = "com.be-huge.insulation-executePuppetEvent" as CFString;
    let observer = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque());
    CFNotificationCenterAddObserver(center, observer, { _, _, _, _, _ in
      IPowerHepler.shared.executePuppetEvent();
    }, executePuppetEventName, nil, .deliverImmediately);
  }
}