//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import Foundation
import UIKit

public class NewStorySheet: OWSTableSheetViewController {
    public required init() {
        super.init()

        tableViewController.defaultSeparatorInsetLeading =
            OWSTableViewController2.cellHInnerMargin + 48 + OWSTableItem.iconSpacing
    }

    public override func updateTableContents(shouldReload: Bool = true) {
        let contents = OWSTableContents()
        defer { tableViewController.setContents(contents, shouldReload: shouldReload) }

        let headerSection = OWSTableSection()
        headerSection.customHeaderHeight = 2
        headerSection.hasBackground = false
        contents.addSection(headerSection)
        headerSection.add(.init(customCellBlock: {
            let label = UILabel()
            label.font = UIFont.ows_dynamicTypeHeadlineClamped
            label.textColor = Theme.primaryTextColor
            label.text = NSLocalizedString("NEW_STORY_SHEET_TITLE", comment: "Title for the new story sheet")
            label.textAlignment = .center

            let cell = OWSTableItem.newCell()
            cell.contentView.addSubview(label)
            label.autoPinEdgesToSuperviewEdges()

            return cell
        }))

        let optionsSection = OWSTableSection()
        optionsSection.customHeaderHeight = 28
        contents.addSection(optionsSection)
        optionsSection.add(buildOptionItem(
            icon: .settingsPrivacy,
            title: NSLocalizedString("NEW_STORY_SHEET_PRIVATE_STORY_TITLE",
                                     comment: "Title for create private story row on the 'new story sheet'"),
            subtitle: NSLocalizedString("NEW_STORY_SHEET_PRIVATE_STORY_SUBTITLE",
                                        comment: "Subitle for create private story row on the 'new story sheet'"),
            action: {

            }))

        optionsSection.add(buildOptionItem(
            icon: .settingsShowGroup,
            title: NSLocalizedString("NEW_STORY_SHEET_GROUP_STORY_TITLE",
                                     comment: "Title for create group story row on the 'new story sheet'"),
            subtitle: NSLocalizedString("NEW_STORY_SHEET_GROUP_STORY_SUBTITLE",
                                        comment: "Subitle for create group story row on the 'new story sheet'"),
            action: {

            }))
    }

    func buildOptionItem(icon: ThemeIcon, title: String, subtitle: String, action: @escaping () -> Void) -> OWSTableItem {
        .init {
            let cell = OWSTableItem.newCell()
            cell.preservesSuperviewLayoutMargins = true
            cell.contentView.preservesSuperviewLayoutMargins = true

            let iconView = OWSTableItem.buildIconInCircleView(
                icon: icon,
                iconSize: AvatarBuilder.standardAvatarSizePoints,
                innerIconSize: 24,
                iconTintColor: Theme.primaryTextColor
            )

            let rowTitleLabel = UILabel()
            rowTitleLabel.text = title
            rowTitleLabel.textColor = Theme.primaryTextColor
            rowTitleLabel.font = .ows_dynamicTypeBodyClamped
            rowTitleLabel.numberOfLines = 0

            let rowSubtitleLabel = UILabel()
            rowSubtitleLabel.text = subtitle
            rowSubtitleLabel.textColor = Theme.secondaryTextAndIconColor
            rowSubtitleLabel.font = .ows_dynamicTypeSubheadlineClamped
            rowSubtitleLabel.numberOfLines = 0

            let titleStack = UIStackView(arrangedSubviews: [ rowTitleLabel, rowSubtitleLabel ])
            titleStack.axis = .vertical
            titleStack.alignment = .leading

            let contentRow = UIStackView(arrangedSubviews: [ iconView, titleStack ])
            contentRow.spacing = ContactCellView.avatarTextHSpacing

            cell.contentView.addSubview(contentRow)
            contentRow.autoPinWidthToSuperviewMargins()
            contentRow.autoPinHeightToSuperview(withMargin: 7)

            return cell
        } actionBlock: { action() }
    }
}