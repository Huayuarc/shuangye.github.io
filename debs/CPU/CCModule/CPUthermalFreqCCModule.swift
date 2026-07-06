import Foundation
import UIKit

@objc(CPUthermalFreqCCModule)
public final class CPUthermalFreqCCModule: NSObject, CCUIContentModule {
    private lazy var moduleContentViewController: UIViewController & CCUIContentModuleContentViewController = CPUthermalFreqCCModuleViewController()

    public var contentViewController: UIViewController & CCUIContentModuleContentViewController {
        moduleContentViewController
    }

}
