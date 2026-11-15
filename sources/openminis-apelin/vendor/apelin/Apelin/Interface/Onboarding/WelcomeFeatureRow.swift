// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Copied from Irisin; only app names, localization calls and flow callbacks differ.
//
//  WelcomeFeatureRow.swift
//  Irisin
//

import SnapKit
import UIKit

/// The feature row from FlowDown's welcome page, with Irisin's content.
final class WelcomeFeatureRow: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let hStack = UIStackView()
    private let contentStack = UIStackView()

    init(feature: WelcomeController.Feature) {
        super.init(frame: .zero)

        hStack.axis = .horizontal
        hStack.spacing = 14
        hStack.alignment = .top

        contentStack.axis = .vertical
        contentStack.spacing = 4
        contentStack.alignment = .leading

        addSubview(hStack)
        hStack.addArrangedSubview(iconView)
        hStack.addArrangedSubview(contentStack)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(detailLabel)

        hStack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        iconView.contentMode = .scaleAspectFit
        iconView.snp.makeConstraints { make in
            make.width.height.equalTo(28)
        }

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = WelcomeStyle.titleColor
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .callout)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = WelcomeStyle.detailColor
        detailLabel.numberOfLines = 0

        iconView.image = UIImage(systemName: feature.symbol)?
            .applyingSymbolConfiguration(WelcomeStyle.featureSymbol)
        iconView.tintColor = WelcomeStyle.accent
        titleLabel.text = String(localized: feature.title)
        detailLabel.text = String(localized: feature.detail)
        accessibilityElements = [titleLabel, detailLabel]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
}
