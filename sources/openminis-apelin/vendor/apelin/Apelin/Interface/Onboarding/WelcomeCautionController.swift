// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Copied from Irisin WelcomeCautionController; title, body and completion adapted.
//
//  WelcomeCautionController.swift
//  Irisin
//
//  The last page of onboarding: the safeguards do not make every change
//  safe, said before the first one.
//

import SnapKit
import Then
import UIKit

class WelcomeCautionController: UIViewController {
    /// The warranty disclaimer from LICENSE, word for word and never
    /// translated: a legal text says what it says in its own words.
    private static let disclaimer = """
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    """

    private let flow: WelcomeFlow

    init(flow: WelcomeFlow) {
        self.flow = flow
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .always
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Disclaimer")
        view.backgroundColor = WelcomeStyle.groupedBackground

        let symbol = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill")).then {
            $0.tintColor = WelcomeStyle.caution
            $0.preferredSymbolConfiguration = .init(pointSize: 44)
        }
        let body = UILabel().then {
            $0.text = String(localized: "Agents can make mistakes. Review generated code and important changes before you run or install them.")
            $0.font = WelcomeStyle.subtitleFont
            $0.textColor = WelcomeStyle.titleColor
            $0.numberOfLines = 0
        }
        let disclaimer = UILabel().then {
            $0.text = Self.disclaimer
            $0.font = WelcomeStyle.detailFont
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 0
        }
        let stack = UIStackView(arrangedSubviews: [symbol, body, disclaimer]).then {
            $0.axis = .vertical
            $0.alignment = .leading
            $0.spacing = 16
            $0.setCustomSpacing(24, after: body)
        }
        let scrollView = UIScrollView().then { $0.alwaysBounceVertical = true }
        let contentView = UIView()
        let actionBar = WelcomeActionBar(title: String(localized: "Get Started")) { [weak self] in
            self?.flow.finish()
        }
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stack)
        view.addSubview(actionBar)

        scrollView.snp.makeConstraints { x in
            x.top.leading.trailing.equalToSuperview()
            x.bottom.equalTo(actionBar.snp.top)
        }
        contentView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.width.equalTo(scrollView.snp.width)
        }
        // under the large title, and in line with it
        stack.snp.makeConstraints { x in
            x.top.equalToSuperview().inset(8)
            x.bottom.equalToSuperview().inset(24)
            x.leading.trailing.equalTo(view.layoutMarginsGuide)
        }
        actionBar.snp.makeConstraints { x in
            x.leading.trailing.bottom.equalToSuperview()
        }
    }
}
