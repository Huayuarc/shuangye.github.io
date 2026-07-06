import Foundation
import UIKit

@objc(CPUthermalCCModule)
public final class CPUthermalCCModule: NSObject, CCUIContentModule {
    private lazy var moduleContentViewController: UIViewController & CCUIContentModuleContentViewController = CPUthermalCCModuleViewController()

    public var contentViewController: UIViewController & CCUIContentModuleContentViewController {
        moduleContentViewController
    }

}
