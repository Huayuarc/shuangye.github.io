import Foundation

class IDictHepler {
  private init() {}

  static let shared = IDictHepler();

  func patchThermalPlist(_ cfDict: CFDictionary) -> CFDictionary {

    let dict = (cfDict as NSDictionary).mutableCopy() as! NSMutableDictionary;

    if let backlight = (dict["backlightComponentControl"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary {

      if let arr = (backlight["BacklightBrightness"] as? NSArray)?.mutableCopy() as? NSMutableArray,
          let first = arr.firstObject {
          for i in 1..<arr.count {
              arr[i] = first;
          }
          backlight["BacklightBrightness"] = arr;
      }

      if let arr = (backlight["BacklightPower"] as? NSArray)?.mutableCopy() as? NSMutableArray,
          let first = arr.firstObject {
          for i in 1..<arr.count {
              arr[i] = first;
          }
          backlight["BacklightPower"] = arr;
      }

      backlight["expectsCPMSSupport"] = NSNumber(value: 0);

      let powerValue = IPowerHepler.shared.getCPUMaxPower();
      if powerValue > 0 {
        backlight["maxThermalPower"] = powerValue;
        backlight["minThermalPower"] = powerValue;
      }

      dict["backlightComponentControl"] = backlight;
    }

    return dict as CFDictionary;
  }
}
