import Foundation

enum ThermalLevelEnum: String {
  case nominal = "nominal";
  case light = "light";
  case moderate = "moderate";
  case heavy = "heavy";

  func next() {
    IPowerHepler.shared.commonProductObject?.putDevice(
      inThermalSimulationMode: self.rawValue
    );
  }
}