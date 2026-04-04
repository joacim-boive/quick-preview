import Cocoa

struct PaywallProductDetails: Equatable {
    let displayName: String
    let displayPrice: String
}

enum PaywallPresentationMode: Equatable {
    case loading
    case blocked(SubscriptionAccessState, PaywallProductDetails?)
}

final class PaywallWindowController: NSWindowController {
    var onSubscribe: (() -> Void)?
    var onRestorePurchases: (() -> Void)?
    var onManageSubscription: (() -> Void)?
    var onOpenAccountPortal: (() -> Void)?
    var onShowHelp: (() -> Void)?
    var onQuit: (() -> Void)?

    private let backgroundView = NSVisualEffectView()
    private let cardContainer = NSView()
    private let appIconView = NSImageView()
    private let eyebrowLabel = NSTextField(labelWithString: "QuickPreview")
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let planCard = NSView()
    private let planNameLabel = NSTextField(labelWithString: "")
    private let planSubtitleLabel = NSTextField(labelWithString: "Then billed monthly unless canceled")
    private let priceLabel = NSTextField(labelWithString: "")
    private let trustLabel = NSTextField(
        wrappingLabelWithString: "Payment is handled by Apple. The subscription renews automatically unless canceled at least 24 hours before the current period ends."
    )
    private let progressIndicator = NSProgressIndicator()
    private let subscribeButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryActionsContainer = NSView()
    private let secondaryButtonRow = NSStackView()
    private let restoreButton = NSButton(title: "Restore Purchases", target: nil, action: nil)
    private let manageButton = NSButton(title: "Manage Subscription", target: nil, action: nil)
    private let helpButton = NSButton(title: "Help", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)

    private var mode: PaywallPresentationMode = .loading
    private var isBusy = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickPreview Subscription"
        window.center()
        self.init(window: window)
        configureUI()
    }

    func apply(mode: PaywallPresentationMode, isBusy: Bool) {
        self.mode = mode
        self.isBusy = isBusy
        render()
    }

    private func configureUI() {
        guard let contentView = window?.contentView else {
            return
        }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .sidebar
        backgroundView.state = .active
        backgroundView.blendingMode = .behindWindow
        contentView.addSubview(backgroundView)

        cardContainer.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.wantsLayer = true
        cardContainer.layer?.cornerRadius = 24
        cardContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
        cardContainer.layer?.borderWidth = 1
        cardContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        backgroundView.addSubview(cardContainer)

        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.image = NSApp.applicationIconImage
        appIconView.wantsLayer = true
        appIconView.layer?.cornerRadius = 18
        cardContainer.addSubview(appIconView)

        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false
        eyebrowLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        eyebrowLabel.textColor = .secondaryLabelColor
        cardContainer.addSubview(eyebrowLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        cardContainer.addSubview(titleLabel)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 14, weight: .regular)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 0
        messageLabel.textColor = .secondaryLabelColor
        cardContainer.addSubview(messageLabel)

        configurePlanCard()
        cardContainer.addSubview(planCard)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        cardContainer.addSubview(progressIndicator)

        subscribeButton.translatesAutoresizingMaskIntoConstraints = false
        subscribeButton.target = self
        subscribeButton.action = #selector(handleSubscribe(_:))
        subscribeButton.bezelStyle = .regularSquare
        subscribeButton.setButtonType(.momentaryPushIn)
        subscribeButton.controlSize = .large
        subscribeButton.keyEquivalent = "\r"
        subscribeButton.contentTintColor = .white
        if #available(macOS 11.0, *) {
            subscribeButton.hasDestructiveAction = false
        }
        cardContainer.addSubview(subscribeButton)

        configureSecondaryButtons()
        cardContainer.addSubview(secondaryActionsContainer)

        quitButton.translatesAutoresizingMaskIntoConstraints = false
        quitButton.target = self
        quitButton.action = #selector(handleQuit(_:))
        quitButton.isBordered = false
        quitButton.font = .systemFont(ofSize: 13, weight: .regular)
        quitButton.contentTintColor = .secondaryLabelColor
        cardContainer.addSubview(quitButton)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: contentView.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            cardContainer.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 28),
            cardContainer.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -28),
            cardContainer.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 24),
            cardContainer.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -24),

            appIconView.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: 28),
            appIconView.centerXAnchor.constraint(equalTo: cardContainer.centerXAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 72),
            appIconView.heightAnchor.constraint(equalToConstant: 72),

            eyebrowLabel.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: 16),
            eyebrowLabel.centerXAnchor.constraint(equalTo: cardContainer.centerXAnchor),

            titleLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 36),
            titleLabel.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -36),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            messageLabel.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 48),
            messageLabel.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -48),

            planCard.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 24),
            planCard.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 44),
            planCard.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -44),

            progressIndicator.topAnchor.constraint(equalTo: planCard.bottomAnchor, constant: 18),
            progressIndicator.centerXAnchor.constraint(equalTo: cardContainer.centerXAnchor),

            subscribeButton.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 18),
            subscribeButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 28),
            subscribeButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -28),
            subscribeButton.heightAnchor.constraint(equalToConstant: 44),

            secondaryActionsContainer.topAnchor.constraint(equalTo: subscribeButton.bottomAnchor, constant: 14),
            secondaryActionsContainer.centerXAnchor.constraint(equalTo: cardContainer.centerXAnchor),

            secondaryButtonRow.leadingAnchor.constraint(equalTo: secondaryActionsContainer.leadingAnchor, constant: 12),
            secondaryButtonRow.trailingAnchor.constraint(equalTo: secondaryActionsContainer.trailingAnchor, constant: -12),
            secondaryButtonRow.topAnchor.constraint(equalTo: secondaryActionsContainer.topAnchor, constant: 12),
            secondaryButtonRow.bottomAnchor.constraint(equalTo: secondaryActionsContainer.bottomAnchor, constant: -12),

            quitButton.topAnchor.constraint(equalTo: secondaryActionsContainer.bottomAnchor, constant: 14),
            quitButton.centerXAnchor.constraint(equalTo: cardContainer.centerXAnchor),
            quitButton.bottomAnchor.constraint(lessThanOrEqualTo: cardContainer.bottomAnchor, constant: -18)
        ])

        render()
    }

    private func configurePlanCard() {
        planCard.translatesAutoresizingMaskIntoConstraints = false
        planCard.wantsLayer = true
        planCard.layer?.cornerRadius = 18
        planCard.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        planCard.layer?.borderWidth = 1
        planCard.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor

        planNameLabel.translatesAutoresizingMaskIntoConstraints = false
        planNameLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        planSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        planSubtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        planSubtitleLabel.textColor = .secondaryLabelColor

        priceLabel.translatesAutoresizingMaskIntoConstraints = false
        priceLabel.font = .systemFont(ofSize: 18, weight: .bold)
        priceLabel.alignment = .right

        trustLabel.translatesAutoresizingMaskIntoConstraints = false
        trustLabel.font = .systemFont(ofSize: 12, weight: .regular)
        trustLabel.textColor = .secondaryLabelColor
        trustLabel.maximumNumberOfLines = 0

        planCard.addSubview(planNameLabel)
        planCard.addSubview(planSubtitleLabel)
        planCard.addSubview(priceLabel)
        planCard.addSubview(trustLabel)

        NSLayoutConstraint.activate([
            planNameLabel.topAnchor.constraint(equalTo: planCard.topAnchor, constant: 16),
            planNameLabel.leadingAnchor.constraint(equalTo: planCard.leadingAnchor, constant: 16),
            planNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: priceLabel.leadingAnchor, constant: -12),

            priceLabel.firstBaselineAnchor.constraint(equalTo: planNameLabel.firstBaselineAnchor),
            priceLabel.trailingAnchor.constraint(equalTo: planCard.trailingAnchor, constant: -16),

            planSubtitleLabel.topAnchor.constraint(equalTo: planNameLabel.bottomAnchor, constant: 4),
            planSubtitleLabel.leadingAnchor.constraint(equalTo: planCard.leadingAnchor, constant: 16),
            planSubtitleLabel.trailingAnchor.constraint(equalTo: planCard.trailingAnchor, constant: -16),

            trustLabel.topAnchor.constraint(equalTo: planSubtitleLabel.bottomAnchor, constant: 12),
            trustLabel.leadingAnchor.constraint(equalTo: planCard.leadingAnchor, constant: 16),
            trustLabel.trailingAnchor.constraint(equalTo: planCard.trailingAnchor, constant: -16),
            trustLabel.bottomAnchor.constraint(equalTo: planCard.bottomAnchor, constant: -16)
        ])
    }

    private func configureSecondaryButtons() {
        secondaryActionsContainer.translatesAutoresizingMaskIntoConstraints = false
        secondaryActionsContainer.wantsLayer = true
        secondaryActionsContainer.layer?.cornerRadius = 12
        secondaryActionsContainer.layer?.backgroundColor = NSColor.underPageBackgroundColor.withAlphaComponent(0.45).cgColor
        secondaryActionsContainer.layer?.borderWidth = 1
        secondaryActionsContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor

        [restoreButton, manageButton, helpButton].forEach { button in
            button.target = self
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setButtonType(.momentaryPushIn)
            if #available(macOS 11.0, *) {
                button.bezelColor = NSColor.controlBackgroundColor.withAlphaComponent(0.9)
            }
        }

        restoreButton.action = #selector(handleRestore(_:))
        manageButton.action = #selector(handleManage(_:))
        helpButton.action = #selector(handleHelp(_:))

        secondaryButtonRow.translatesAutoresizingMaskIntoConstraints = false
        secondaryButtonRow.orientation = .horizontal
        secondaryButtonRow.alignment = .centerY
        secondaryButtonRow.distribution = .fillProportionally
        secondaryButtonRow.spacing = 0
        [restoreButton, manageButton, helpButton].forEach(secondaryButtonRow.addArrangedSubview(_:))
        secondaryActionsContainer.addSubview(secondaryButtonRow)
    }

    private func render() {
        switch mode {
        case .loading:
            titleLabel.stringValue = "Checking your subscription"
            messageLabel.stringValue = "QuickPreview is confirming your App Store access before opening the player."
            planNameLabel.stringValue = "QuickPreview Monthly"
            priceLabel.stringValue = "Loading..."
            planSubtitleLabel.stringValue = "Then billed monthly unless canceled"
            trustLabel.stringValue = "Payment is handled by Apple. The subscription renews automatically unless canceled at least 24 hours before the current period ends."
            subscribeButton.title = "Preparing purchase options..."
            subscribeButton.isHidden = true
            secondaryButtonRow.isHidden = true
            secondaryActionsContainer.isHidden = true
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        case .blocked(let accessState, let productDetails):
            titleLabel.stringValue = titleText(for: accessState)
            messageLabel.stringValue = messageText(for: accessState, productDetails: productDetails)
            planNameLabel.stringValue = productDetails?.displayName ?? "QuickPreview Monthly"
            priceLabel.stringValue = productPriceText(from: productDetails)
            planSubtitleLabel.stringValue = subtitleText(for: accessState)
            trustLabel.stringValue = legalText(for: accessState)
            subscribeButton.title = primaryActionTitle(for: accessState)
            subscribeButton.isHidden = false
            secondaryButtonRow.isHidden = false
            secondaryActionsContainer.isHidden = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
        }

        subscribeButton.isEnabled = !isBusy && !subscribeButton.isHidden
        restoreButton.isEnabled = !isBusy && !secondaryButtonRow.isHidden
        manageButton.isHidden = false
        manageButton.isEnabled = !isBusy && !secondaryButtonRow.isHidden
        helpButton.isHidden = AppEdition.current == .pro
        helpButton.isEnabled = !isBusy && !helpButton.isHidden
        quitButton.isEnabled = !isBusy

        if AppEdition.current == .pro {
            restoreButton.title = "Open Account Portal"
            manageButton.title = "QuickPreview PRO Help"
        } else {
            restoreButton.title = "Restore Purchases"
            manageButton.title = "Manage Subscription"
            helpButton.title = "Account & QuickPreview PRO"
        }

        if isBusy {
            subscribeButton.title = AppEdition.current == .appStore ? "Contacting App Store..." : "Checking QuickPreview PRO access..."
        }
    }

    private func primaryActionTitle(for accessState: SubscriptionAccessState) -> String {
        if AppEdition.current == .pro {
            return "Open Account Portal"
        }

        switch accessState {
        case .expired, .refunded, .revoked:
            return "Subscribe"
        case .notEntitled,
             .unknown,
             .verifying,
             .trialActive,
             .subscriptionActive,
             .inGracePeriod,
             .inBillingRetry,
             .offlineGracePeriod:
            return "Start Free Trial"
        }
    }

    private func productPriceText(from productDetails: PaywallProductDetails?) -> String {
        if AppEdition.current == .pro {
            return "Included"
        }

        guard let productDetails else {
            return "$1.99 / month"
        }

        return "\(productDetails.displayPrice) / month"
    }

    private func messageText(
        for accessState: SubscriptionAccessState,
        productDetails: PaywallProductDetails?
    ) -> String {
        let productName = productDetails?.displayName ?? "QuickPreview"

        if AppEdition.current == .pro {
            switch accessState {
            case .expired, .refunded, .revoked, .notEntitled:
                return "QuickPreview PRO is included for active QuickPreview subscribers. Link your App Store subscription through the account portal, then sign in here to unlock Finder integration."
            case .unknown,
                 .verifying,
                 .trialActive,
                 .subscriptionActive,
                 .inGracePeriod,
                 .inBillingRetry,
                 .offlineGracePeriod:
                return "QuickPreview PRO checks your mirrored subscriber access through the account portal before opening the player."
            }
        }

        switch accessState {
        case .expired:
            return "Your subscription has ended. Subscribe again to continue using \(productName)."
        case .refunded:
            return "This subscription was refunded. Start a new subscription to continue using QuickPreview."
        case .revoked:
            return "This Apple account no longer has access to the subscription. Subscribe again or restore an eligible purchase."
        case .notEntitled:
            return "Unlock QuickPreview Premium with a 1-month free trial."
        case .unknown,
             .verifying,
             .trialActive,
             .subscriptionActive,
             .inGracePeriod,
             .inBillingRetry,
             .offlineGracePeriod:
            return "A valid App Store subscription is required to use \(productName)."
        }
    }

    private func titleText(for accessState: SubscriptionAccessState) -> String {
        if AppEdition.current == .pro {
            switch accessState {
            case .expired, .refunded, .revoked, .notEntitled:
                return "Sign in to QuickPreview PRO"
            case .unknown,
                 .verifying,
                 .trialActive,
                 .subscriptionActive,
                 .inGracePeriod,
                 .inBillingRetry,
                 .offlineGracePeriod:
                return "Checking QuickPreview PRO access"
            }
        }

        switch accessState {
        case .expired, .refunded, .revoked:
            return "Subscribe to continue"
        case .notEntitled,
             .unknown,
             .verifying,
             .trialActive,
             .subscriptionActive,
             .inGracePeriod,
             .inBillingRetry,
             .offlineGracePeriod:
            return "Start your 1-month free trial"
        }
    }

    private func subtitleText(for accessState: SubscriptionAccessState) -> String {
        if AppEdition.current == .pro {
            switch accessState {
            case .expired, .refunded, .revoked:
                return "Included for active QuickPreview subscribers"
            case .notEntitled,
                 .unknown,
                 .verifying,
                 .trialActive,
                 .subscriptionActive,
                 .inGracePeriod,
                 .inBillingRetry,
                 .offlineGracePeriod:
                return "Use the account portal to link and validate access"
            }
        }

        switch accessState {
        case .expired, .refunded, .revoked:
            return "Billed monthly unless canceled"
        case .notEntitled,
             .unknown,
             .verifying,
             .trialActive,
             .subscriptionActive,
             .inGracePeriod,
             .inBillingRetry,
             .offlineGracePeriod:
            return "Then billed monthly unless canceled"
        }
    }

    private func legalText(for accessState: SubscriptionAccessState) -> String {
        if AppEdition.current == .pro {
            switch accessState {
            case .expired, .refunded, .revoked:
                return "QuickPreview PRO does not bill directly. Keep your QuickPreview subscription active in the Mac App Store, then relink access through the account portal if needed."
            case .notEntitled,
                 .unknown,
                 .verifying,
                 .trialActive,
                 .subscriptionActive,
                 .inGracePeriod,
                 .inBillingRetry,
                 .offlineGracePeriod:
                return "Your PRO unlock is mirrored from an active QuickPreview subscription and periodically revalidated through the account portal."
            }
        }

        switch accessState {
        case .expired, .refunded, .revoked:
            return "Payment is handled by Apple. Subscription management and renewal settings are available in the App Store."
        case .notEntitled,
             .unknown,
             .verifying,
             .trialActive,
             .subscriptionActive,
             .inGracePeriod,
             .inBillingRetry,
             .offlineGracePeriod:
            return "Payment is charged to your Apple Account at confirmation. The subscription renews automatically unless canceled at least 24 hours before the current period ends."
        }
    }

    @objc
    private func handleSubscribe(_ sender: Any?) {
        _ = sender
        onSubscribe?()
    }

    @objc
    private func handleRestore(_ sender: Any?) {
        _ = sender
        if AppEdition.current == .pro {
            onOpenAccountPortal?()
        } else {
            onRestorePurchases?()
        }
    }

    @objc
    private func handleManage(_ sender: Any?) {
        _ = sender
        if AppEdition.current == .pro {
            onShowHelp?()
        } else {
            onManageSubscription?()
        }
    }

    @objc
    private func handleHelp(_ sender: Any?) {
        _ = sender
        if AppEdition.current == .pro {
            onShowHelp?()
        } else {
            onOpenAccountPortal?()
        }
    }

    @objc
    private func handleQuit(_ sender: Any?) {
        _ = sender
        onQuit?()
    }
}
