import UserNotifications
import MobileCoreServices

class IPNotificationHelper {
  static let shared = IPNotificationHelper();

  func sendMsg(name: String) {
    let center = CFNotificationCenterGetDarwinNotifyCenter();
    let _name = name as CFString;
    let object = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque());
    CFNotificationCenterPostNotification(center, .init(_name), object, nil, true);
  }
}