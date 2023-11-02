//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AuthenticationServices
import SignalMessaging
import SignalUI

import SwiftUI

class BankTransferMandateViewController: OWSViewController, OWSNavigationChildController {
    var preferredNavigationBarStyle: OWSNavigationBarStyle { .solid }
    var navbarBackgroundColorOverride: UIColor? { .clear }

    private var didAgree: (Stripe.PaymentMethod.Mandate) -> Void

    init(didAgree: @escaping (Stripe.PaymentMethod.Mandate) -> Void) {
        self.didAgree = didAgree
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let hostingController = UIHostingController(rootView: BankTransferMandateView(didAgree: self.didAgree))

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.autoPinEdgesToSuperviewEdges()
        hostingController.didMove(toParent: self)

        // TODO: [SEPA] Add cancel button
    }

    // TODO: [SEPA] Respond to dark mode
}

struct BankTransferMandateView: View {
    var didAgree: (Stripe.PaymentMethod.Mandate) -> Void

    // TODO: [SEPA] Pull localized mandate strings

    var body: some View {
        ScrollView(.vertical) {
            VStack {
                // TODO: [SEPA] Theme
                Image(systemName: "building.columns")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .padding()
                    .background(Circle().fill(.white))

                Text("Bank Transfer")
                    .font(Font(UIFont.dynamicTypeTitle1.semibold()))

                Text("Stripe processes donations made to Signal. Signal does not collect or store your personal information.")
                    .font(Font(UIFont.dynamicTypeBodyClamped))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                // TODO: [SEPA] Theme
                Text("""
                By providing your payment information and confirming this payment, you authorise (A) Signal Technology Foundation and Stripe, our payment service provider, to send instructions to your bank to debit your account and (B) your bank to debit your account in accordance with those instructions. As part of your rights, you are entitled to a refund from your bank under the terms and conditions of your agreement with your bank. A refund must be claimed within 8 weeks starting from the date on which your account was debited. Your rights are explained in a statement that you can obtain from your bank. You agree to receive notifications for future debits up to 2 days before they occur.
                """)
                .font(Font(UIFont.dynamicTypeBody))
                // TODO: [SEPA] "Learn more" link
                .padding()
                .background(Color.white)
                .cornerRadius(10)
                .padding(.vertical, 8)

                Button {
                    didAgree(.accept())
                } label: {
                    HStack {
                        Spacer()
                        Text("Agree")
                        Spacer()
                    }
                }
                .font(Font(UIFont.dynamicTypeHeadline))
                .padding()
                .foregroundColor(.white)
                .background(Color.accentColor)
                .cornerRadius(12)
                .padding(.horizontal, 40)
            }
            .padding()
        }
        .background(Color(Theme.tableView2PresentedBackgroundColor).edgesIgnoringSafeArea(.all))
    }
}

class DonationPaymentDetailsViewController: OWSTableViewController2 {
    enum PaymentMethod {
        case card
        case sepa(mandate: Stripe.PaymentMethod.Mandate)

        var stripePaymentMethod: OWSRequestFactory.StripePaymentMethod {
            switch self {
            case .card:
                return .card
            case .sepa:
                return .bankTransfer(.sepa)
            }
        }
    }

    let donationAmount: FiatMoney
    let donationMode: DonationMode
    let paymentMethod: PaymentMethod
    let onFinished: () -> Void
    var threeDSecureAuthenticationSession: ASWebAuthenticationSession?

    public override var preferredNavigationBarStyle: OWSNavigationBarStyle { .solid }
    public override var navbarBackgroundColorOverride: UIColor? { .clear }

    init(
        donationAmount: FiatMoney,
        donationMode: DonationMode,
        paymentMethod: PaymentMethod,
        onFinished: @escaping () -> Void
    ) {
        self.donationAmount = donationAmount
        self.donationMode = donationMode
        self.paymentMethod = paymentMethod
        self.onFinished = onFinished

        super.init()

        self.defaultSpacingBetweenSections = 0
    }

    deinit {
        threeDSecureAuthenticationSession?.cancel()
    }

    // MARK: - View callbacks

    public override func viewDidLoad() {
        shouldAvoidKeyboard = true

        super.viewDidLoad()

        render()

        contents = OWSTableContents(sections: [donationAmountSection, formSection])
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        cardNumberView.becomeFirstResponder()
    }

    public override func themeDidChange() {
        super.themeDidChange()

        render()
    }

    // MARK: - Events

    private func didSubmit() {
        // TODO: Dismiss keyboard?
        switch formState {
        case .invalid, .potentiallyValid:
            owsFail("[Donations] It should be impossible to submit the form without a fully-valid card. Is the submit button properly disabled?")
        case let .fullyValid(validForm):
            switch donationMode {
            case .oneTime:
                oneTimeDonation(with: validForm)
            case let .monthly(
                subscriptionLevel,
                subscriberID,
                _,
                currentSubscriptionLevel
            ):
                monthlyDonation(
                    with: validForm,
                    newSubscriptionLevel: subscriptionLevel,
                    priorSubscriptionLevel: currentSubscriptionLevel,
                    subscriberID: subscriberID
                )
            case let .gift(thread, messageText):
                switch validForm {
                case let .card(creditOrDebitCard):
                    giftDonation(with: creditOrDebitCard, in: thread, messageText: messageText)
                case .sepa:
                    owsFailDebug("Gift badges do not support bank transfers")
                }
            }
        }
    }

    func didFailDonation(error: Error) {
        DonationViewsUtil.presentDonationErrorSheet(
            from: self,
            error: error,
            paymentMethod: .creditOrDebitCard,
            currentSubscription: {
                switch donationMode {
                case .oneTime, .gift: return nil
                case let .monthly(_, _, currentSubscription, _): return currentSubscription
                }
            }()
        )
    }

    // MARK: - Rendering

    private func render() {
        // We'd like a link that doesn't go anywhere, because we'd like to
        // handle the tapping ourselves. We use a "fake" URL because BonMot
        // needs one.
        let linkPart = StringStyle.Part.link(SupportConstants.subscriptionFAQURL)

        subheaderTextView.attributedText = .composed(of: [
            OWSLocalizedString(
                "CARD_DONATION_SUBHEADER_TEXT",
                comment: "On the credit/debit card donation screen, a small amount of information text is shown. This is that text. It should (1) instruct users to enter their credit/debit card information (2) tell them that Signal does not collect or store their personal information."
            ),
            " ",
            OWSLocalizedString(
                "CARD_DONATION_SUBHEADER_LEARN_MORE",
                comment: "On the credit/debit card donation screen, a small amount of information text is shown. Users can click this link to learn more information."
            ).styled(with: linkPart)
        ]).styled(with: .color(Theme.primaryTextColor), .font(.dynamicTypeBody))
        subheaderTextView.linkTextAttributes = [
            .foregroundColor: Theme.accentBlueColor,
            .underlineColor: UIColor.clear,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        subheaderTextView.textAlignment = .center

        // Only change the placeholder when enough digits are entered.
        // Helps avoid a jittery UI as you type/delete.
        let rawNumber = cardNumberView.text
        let cardType = CreditAndDebitCards.cardType(ofNumber: rawNumber)
        if rawNumber.count >= 2 {
            cvvView.placeholder = String("1234".prefix(cardType.cvvCount))
        }

        let invalidFields: Set<InvalidFormField>
        switch formState {
        case let .invalid(fields):
            invalidFields = fields
            submitButton.isEnabled = false
        case .potentiallyValid:
            invalidFields = []
            submitButton.isEnabled = false
        case .fullyValid:
            invalidFields = []
            submitButton.isEnabled = true
        }

        tableView.beginUpdates()
        cardNumberView.render(errorMessage: {
            guard invalidFields.contains(.cardNumber) else { return nil }
            return OWSLocalizedString(
                "CARD_DONATION_CARD_NUMBER_GENERIC_ERROR",
                comment: "Users can donate to Signal with a credit or debit card. If their card number is invalid, this generic error message will be shown. Try to use a short string to make space in the UI."
            )
        }())
        expirationView.render(errorMessage: {
            guard invalidFields.contains(.expirationDate) else { return nil }
            return OWSLocalizedString(
                "CARD_DONATION_EXPIRATION_DATE_GENERIC_ERROR",
                comment: "Users can donate to Signal with a credit or debit card. If their expiration date is invalid, this generic error message will be shown. Try to use a short string to make space in the UI."
            )
        }())
        cvvView.render(errorMessage: {
            guard invalidFields.contains(.cvv) else { return nil }
            if cvvView.text.count > cardType.cvvCount {
                return OWSLocalizedString(
                    "CARD_DONATION_CVV_TOO_LONG_ERROR",
                    comment: "Users can donate to Signal with a credit or debit card. If their card verification code (CVV) is too long, this error will be shown. Try to use a short string to make space in the UI."
                )
            } else {
                return OWSLocalizedString(
                    "CARD_DONATION_CVV_GENERIC_ERROR",
                    comment: "Users can donate to Signal with a credit or debit card. If their card verification code (CVV) is invalid for reasons we cannot determine, this generic error message will be shown. Try to use a short string to make space in the UI."
                )
            }
        }())
        ibanView.render(errorMessage: ibanErrorMessage(invalidFields: invalidFields))
        // Currently, name and email can only be valid or potentially
        // valid. There is no invalid state for either.
        tableView.endUpdates()

        bottomFooterStackView.layer.backgroundColor = self.tableBackgroundColor.cgColor
    }

    private func ibanErrorMessage(invalidFields: Set<InvalidFormField>) -> String? {
        invalidFields.lazy
            .compactMap { field -> SEPABankAccounts.IBANInvalidity? in
                guard case let .iban(invalidity) = field else { return nil }
                return invalidity
            }
            .first
            .map { invalidity in
                switch invalidity {
                case .invalidCharacters:
                    return OWSLocalizedString(
                        "SEPA_DONATION_IBAN_INVALID_CHARACTERS_ERROR",
                        comment: "Users can donate to Signal with a bank account. If their internation bank account number (IBAN) contains characters other than letters and numbers, this error will be shown. Try to use a short string to make space in the UI."
                    )
                case .invalidCheck:
                    return OWSLocalizedString(
                        "SEPA_DONATION_IBAN_INVALID_CHECK_ERROR",
                        comment: "Users can donate to Signal with a bank account. If their internation bank account number (IBAN) does not pass validation, this error will be shown. Try to use a short string to make space in the UI."
                    )
                case .invalidCountry:
                    return OWSLocalizedString(
                        "SEPA_DONATION_IBAN_INVALID_COUNTRY_ERROR",
                        comment: "Users can donate to Signal with a bank account. If their internation bank account number (IBAN) has an unsupported country code, this error will be shown. Try to use a short string to make space in the UI."
                    )
                case .tooLong:
                    return OWSLocalizedString(
                        "SEPA_DONATION_IBAN_TOO_LONG_ERROR",
                        comment: "Users can donate to Signal with a bank account. If their internation bank account number (IBAN) is too long, this error will be shown. Try to use a short string to make space in the UI."
                    )
                case .tooShort:
                    return OWSLocalizedString(
                        "SEPA_DONATION_IBAN_TOO_SHORT_ERROR",
                        comment: "Users can donate to Signal with a bank account. If their internation bank account number (IBAN) is too long, this error will be shown. Try to use a short string to make space in the UI."
                    )
                }
            }
    }

    // MARK: - Donation amount section

    private lazy var subheaderTextView: LinkingTextView = {
        let result = LinkingTextView()
        result.delegate = self
        return result
    }()

    private lazy var donationAmountSection: OWSTableSection = {
        let result = OWSTableSection(
            items: [.init(
                customCellBlock: { [weak self] in
                    let cell = OWSTableItem.newCell()
                    cell.selectionStyle = .none

                    guard let self else { return cell }

                    let headerLabel = UILabel()
                    headerLabel.text = {
                        let amountString = DonationUtilities.format(money: self.donationAmount)
                        let format: String
                        switch self.donationMode {
                        case .oneTime, .gift:
                            format = OWSLocalizedString(
                                "CARD_DONATION_HEADER",
                                comment: "Users can donate to Signal with a credit or debit card. This is the heading on that screen, telling them how much they'll donate. Embeds {{formatted amount of money}}, such as \"$20\"."
                            )
                        case .monthly:
                            format = OWSLocalizedString(
                                "CARD_DONATION_HEADER_MONTHLY",
                                comment: "Users can donate to Signal with a credit or debit card. This is the heading on that screen, telling them how much they'll donate every month. Embeds {{formatted amount of money}}, such as \"$20\"."
                            )
                        }
                        return String(format: format, amountString)
                    }()
                    headerLabel.font = .dynamicTypeTitle3.semibold()
                    headerLabel.textAlignment = .center
                    headerLabel.numberOfLines = 0
                    headerLabel.lineBreakMode = .byWordWrapping

                    let stackView = UIStackView(arrangedSubviews: [
                        headerLabel,
                        self.subheaderTextView
                    ])
                    cell.contentView.addSubview(stackView)
                    stackView.axis = .vertical
                    stackView.spacing = 4
                    stackView.autoPinEdgesToSuperviewMargins()

                    return cell
                }
            )]
        )
        result.hasBackground = false
        return result
    }()

    // MARK: - Form

    private var formState: FormState {
        switch self.paymentMethod {
        case .card:
            return Self.formState(
                cardNumber: cardNumberView.text,
                isCardNumberFieldFocused: cardNumberView.isFirstResponder,
                expirationDate: expirationView.text,
                cvv: cvvView.text
            )
        case let .sepa(mandate: mandate):
            return Self.formState(
                mandate: mandate,
                iban: ibanView.text,
                isIBANFieldFocused: ibanView.isFirstResponder,
                name: nameView.text,
                email: emailView.text,
                isEmailFieldFocused: emailView.isFirstResponder
            )
        }
    }

    private lazy var formSection: OWSTableSection = {
        switch self.paymentMethod {
        case .card:
            return creditCardFormSection
        case .sepa:
            return sepaFormSection
        }
    }()

    private static func cell(for formFieldView: FormFieldView) -> OWSTableItem {
        .init(customCellBlock: { [weak formFieldView] in
            let cell = OWSTableItem.newCell()
            cell.selectionStyle = .none
            guard let formFieldView else { return cell }
            cell.contentView.addSubview(formFieldView)
            formFieldView.autoPinEdgesToSuperviewMargins()
            return cell
        })
    }

    // MARK: Form field title strings

    private static let cardNumberTitle = OWSLocalizedString(
        "CARD_DONATION_CARD_NUMBER_LABEL",
        comment: "Users can donate to Signal with a credit or debit card. This is the label for the card number field on that screen."
    )

    private static let cardNumberPlaceholder = "0000000000000000"

    private static let expirationTitle = OWSLocalizedString(
        "CARD_DONATION_EXPIRATION_DATE_LABEL",
        comment: "Users can donate to Signal with a credit or debit card. This is the label for the expiration date field on that screen. Try to use a short string to make space in the UI. (For example, the English text uses \"Exp. Date\" instead of \"Expiration Date\")."
    )

    private static let cvvTitle = OWSLocalizedString(
        "CARD_DONATION_CVV_LABEL",
        comment: "Users can donate to Signal with a credit or debit card. This is the label for the card verification code (CVV) field on that screen."
    )

    private static let ibanTitle = OWSLocalizedString(
        "SEPA_DONATION_IBAN_LABEL",
        comment: "Users can donate to Signal with a bank account. This is the label for IBAN (internation bank account number) field on that screen."
    )

    private static let ibanPlaceholder = "DE00000000000000000000"

    private static let nameTitle = OWSLocalizedString(
        "SEPA_DONATION_NAME_LABEL",
        comment: "Users can donate to Signal with a bank account. This is the label for name field on that screen."
    )

    private static let emailTitle = OWSLocalizedString(
        "SEPA_DONATION_EMAIL_LABEL",
        comment: "Users can donate to Signal with a bank account. This is the label for email field on that screen."
    )

    // MARK: Form field title styles

    private lazy var cardFormTitleLayout: FormFieldView.TitleLayout = titleLayout(
        for: [
            Self.cardNumberTitle,
            Self.expirationTitle,
            Self.cvvTitle,
        ],
        titleWidth: 120,
        placeholder: Self.formatCardNumber(unformatted: Self.cardNumberPlaceholder)
    )

    private lazy var sepaFormTitleLayout: FormFieldView.TitleLayout = titleLayout(
        for: [
            Self.ibanTitle,
            Self.nameTitle,
            Self.emailTitle,
        ],
        titleWidth: 60,
        placeholder: Self.formatIBAN(unformatted: Self.ibanPlaceholder)
    )

    private func titleLayout(for titles: [String], titleWidth: CGFloat, placeholder: String) -> FormFieldView.TitleLayout {
        guard
            Self.canTitlesFitInWidth(titles: titles, width: titleWidth),
            self.canPlaceholderFitInAvailableWidth(
                placeholder: placeholder,
                headerWidth: titleWidth
            )
        else { return .compact }

        return .inline(width: titleWidth)
    }

    private static func canTitlesFitInWidth(titles: [String], width: CGFloat) -> Bool {
        titles.allSatisfy { title in
            FormFieldView.titleAttributedString(title).size().width <= width
        }
    }

    private func canPlaceholderFitInAvailableWidth(placeholder: String, headerWidth: CGFloat) -> Bool {
        let placeholderTextWidth = NSAttributedString(string: placeholder, attributes: [.font: FormFieldView.textFieldFont]).size().width
        let insets = self.cellOuterInsets.totalWidth + Self.cellHInnerMargin * 2
        let totalWidth = placeholderTextWidth + insets + headerWidth + FormFieldView.titleSpacing
        return totalWidth <= self.view.width
    }

    // MARK: - Card form

    private lazy var creditCardFormSection = OWSTableSection(items: [
        Self.cell(for: self.cardNumberView),
        Self.cell(for: self.expirationView),
        Self.cell(for: self.cvvView),
    ])

    // MARK: Card number

    static func formatCardNumber(unformatted: String) -> String {
        var gaps: Set<Int>
        switch CreditAndDebitCards.cardType(ofNumber: unformatted) {
        case .americanExpress: gaps = [4, 10]
        case .unionPay, .other: gaps = [4, 8, 12]
        }

        var result = [Character]()
        for (i, character) in unformatted.enumerated() {
            if gaps.contains(i) {
                result.append(" ")
            }
            result.append(character)
        }
        if gaps.contains(unformatted.count) {
            result.append(" ")
        }
        return String(result)
    }

    private lazy var cardNumberView = FormFieldView(
        title: Self.cardNumberTitle,
        titleLayout: self.cardFormTitleLayout,
        placeholder: Self.formatCardNumber(unformatted: Self.cardNumberPlaceholder),
        style: .formatted(
            format: Self.formatCardNumber(unformatted:),
            allowedCharacters: .numbers,
            maxDigits: 19
        ),
        textContentType: .creditCardNumber,
        delegate: self
    )

    // MARK: Expiration date

    static func formatExpirationDate(unformatted: String) -> String {
        switch unformatted.count {
        case 0:
            return unformatted
        case 1:
            let firstDigit = unformatted.first!
            switch firstDigit {
            case "0", "1": return unformatted
            default: return unformatted + "/"
            }
        case 2:
            if (UInt8(unformatted) ?? 0).isValidAsMonth {
                return unformatted + "/"
            } else {
                return "\(unformatted.prefix(1))/\(unformatted.suffix(1))"
            }
        default:
            let firstTwo = unformatted.prefix(2)
            let firstTwoAsMonth = UInt8(String(firstTwo)) ?? 0
            let monthCount = firstTwoAsMonth.isValidAsMonth ? 2 : 1
            let month = unformatted.prefix(monthCount)
            let year = unformatted.suffix(unformatted.count - monthCount)
            return "\(month)/\(year)"
        }
    }

    private lazy var expirationView = FormFieldView(
        title: Self.expirationTitle,
        titleLayout: self.cardFormTitleLayout,
        placeholder: OWSLocalizedString(
            "CARD_DONATION_EXPIRATION_DATE_PLACEHOLDER",
            comment: "Users can donate to Signal with a credit or debit card. This is the label for the card expiration date field on that screen."
        ),
        style: .formatted(
            format: Self.formatExpirationDate(unformatted:),
            allowedCharacters: .numbers,
            maxDigits: 4
        ),
        textContentType: nil, // TODO: Add content type for iOS 17
        delegate: self
    )

    // MARK: CVV

    private lazy var cvvView = FormFieldView(
        title: Self.cvvTitle,
        titleLayout: self.cardFormTitleLayout,
        placeholder: "123",
        style: .formatted(
            format: { $0 },
            allowedCharacters: .numbers,
            maxDigits: 4
        ),
        textContentType: nil, // TODO: Add content type for iOS 17,
        delegate: self
    )

    // MARK: - SEPA form

    private lazy var sepaFormSection = OWSTableSection(items: [
        Self.cell(for: self.ibanView),
        Self.cell(for: self.nameView),
        Self.cell(for: self.emailView),
    ])

    // MARK: IBAN

    static func formatIBAN(unformatted: String) -> String {
        let gaps: Set<Int> = [4, 8, 12, 16, 20, 24, 28, 32]

        var result = unformatted.enumerated().reduce(into: [Character]()) { (partialResult, item) in
            let (i, character) = item
            if gaps.contains(i) {
                partialResult.append(" ")
            }
            partialResult.append(character)
        }
        if gaps.contains(unformatted.count) {
            result.append(" ")
        }
        return String(result)
    }

    private lazy var ibanView: FormFieldView = FormFieldView(
        title: Self.ibanTitle,
        titleLayout: self.sepaFormTitleLayout,
        placeholder: Self.formatIBAN(unformatted: Self.ibanPlaceholder),
        style: .formatted(
            format: Self.formatIBAN(unformatted:),
            allowedCharacters: .alphanumeric,
            maxDigits: 34
        ),
        textContentType: nil,
        delegate: self
    )

    // MARK: Name & Email

    private lazy var nameView = FormFieldView(
        title: Self.nameTitle,
        titleLayout: self.sepaFormTitleLayout,
        placeholder: OWSLocalizedString(
            "SEPA_DONATION_NAME_PLACEHOLDER",
            comment: "Users can donate to Signal with a bank account. This is placeholder text for the name field before the user starts typing."
        ),
        style: .plain(keyboardType: .default),
        textContentType: .name,
        delegate: self
    )

    private lazy var emailView = FormFieldView(
        title: Self.emailTitle,
        titleLayout: self.sepaFormTitleLayout,
        placeholder: OWSLocalizedString(
            "SEPA_DONATION_EMAIL_PLACEHOLDER",
            comment: "Users can donate to Signal with a bank account. This is placeholder text for the email field before the user starts typing."
        ),
        style: .plain(keyboardType: .emailAddress),
        textContentType: .emailAddress,
        delegate: self
    )

    // MARK: - Submit button, footer

    private lazy var submitButton: OWSButton = {
        let title = OWSLocalizedString(
            "CARD_DONATION_DONATE_BUTTON",
            comment: "Users can donate to Signal with a credit or debit card. This is the text on the \"Donate\" button."
        )
        let result = OWSButton(title: title) { [weak self] in
            self?.didSubmit()
        }
        result.dimsWhenHighlighted = true
        result.dimsWhenDisabled = true
        result.layer.cornerRadius = 8
        result.backgroundColor = .ows_accentBlue
        result.titleLabel?.font = .dynamicTypeBody.semibold()
        result.autoSetDimension(.height, toSize: 48, relation: .greaterThanOrEqual)
        return result
    }()

    private lazy var bottomFooterStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [submitButton])

        result.axis = .vertical
        result.alignment = .fill
        result.spacing = 16
        result.isLayoutMarginsRelativeArrangement = true
        result.preservesSuperviewLayoutMargins = true
        result.layoutMargins = .init(hMargin: 16, vMargin: 10)

        return result
    }()

    open override var bottomFooter: UIView? {
        get { bottomFooterStackView }
        set {}
    }
}

// MARK: - UITextViewDelegate

extension DonationPaymentDetailsViewController: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        if textView == subheaderTextView {
            present(DonationPaymentDetailsReadMoreSheetViewController(), animated: true)
        }
        return false
    }
}

// MARK: - CreditOrDebitCardDonationFormViewDelegate

extension DonationPaymentDetailsViewController: CreditOrDebitCardDonationFormViewDelegate {
    func didSomethingChange() { render() }
}

// MARK: - Utilities

fileprivate extension UInt8 {
    var isValidAsMonth: Bool { self >= 1 && self <= 12 }
}
