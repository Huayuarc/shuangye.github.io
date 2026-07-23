import Foundation

class IFileManager {
  static func getPlistContent(withPath prefsPath: String) -> [String: Any] {
    let url = URL(fileURLWithPath: prefsPath)
    guard let data = try? Data(contentsOf: url) else {
      return [:];
    }

    var format: PropertyListSerialization.PropertyListFormat = .binary;
    guard let plist = try? PropertyListSerialization.propertyList(
      from: data,
      options: .mutableContainers,
      format: &format
    ) as? [String: Any] else {
      return [:];
    }

    return plist;
  }
}