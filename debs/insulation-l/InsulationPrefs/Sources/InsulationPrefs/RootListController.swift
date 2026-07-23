import Preferences
import InsulationPrefsC

class RootListController: PSListController {
    override var specifiers: NSMutableArray? {
        get {
            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }
            let specifiers = loadSpecifiers(fromPlistName: "Root", target: self);
            setValue(specifiers, forKey: "_specifiers");
            return specifiers;
        }
        set {
            super.specifiers = newValue
        }
    }

    override func readPreferenceValue(_ specifier: PSSpecifier?) -> Any? {
        let prefs = NSDictionary(contentsOfFile: prefsPlistPath);
        let key = specifier?.properties.object(forKey: "key") as Any;
        let `default` = specifier?.properties.object(forKey: "default") as Any;

        return prefs?.object(forKey: key) ?? `default`;
    }

    override func setPreferenceValue(_ value: Any, specifier: PSSpecifier) {
        let prefs = NSMutableDictionary(contentsOfFile: prefsPlistPath) ?? .init();
        let key = specifier.properties.object(forKey: "key") as! NSCopying;
        prefs.setObject(value as Any, forKey: key);
        prefs.write(toFile: prefsPlistPath, atomically: true);

        let keyString = key as! String;
        if keyString == "thermalPuppetValue" {
            IPNotificationHelper.shared.sendMsg(name: "com.be-huge.insulation-executePuppetEvent");
        }
    }
}
