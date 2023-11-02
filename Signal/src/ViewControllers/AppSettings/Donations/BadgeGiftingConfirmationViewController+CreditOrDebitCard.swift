//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

extension BadgeGiftingConfirmationViewController {
    func startCreditOrDebitCard() {
        guard let navigationController else {
            owsFail("[Gifting] Cannot open credit/debit card screen if we're not in a navigation controller")
        }

        let vc = DonationPaymentDetailsViewController(
            donationAmount: price,
            donationMode: .gift(thread: thread, messageText: messageText),
            // Gifting does not support bank transfers
            paymentMethod: .card
        ) { [weak self] in
            self?.didCompleteDonation()
        }
        navigationController.pushViewController(vc, animated: true)
    }
}
