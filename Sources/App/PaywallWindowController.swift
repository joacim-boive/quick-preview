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
    var onShowHelp: (() -> Void)?
    var onQuit: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let priceLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let subscribeButton = NSButton(title: "", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore Purchases", target: nil, action: nil)
    private let manageButton = NSButton(title: "Manage Subscription", target: nil, action: nil)
    private let helpButton = NSButton(title: "Help", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let buttonStack = NSStackView()

    private var mode: PaywallPresentationMode = .loading
    private var isBusy = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
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

        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.alignment = .center

        messageLabel.font = .systemFont(ofSize: 14, weight: .regular)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 0
        messageLabel.textColor = .secondaryLabelColor

        priceLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        priceLabel.alignment = .center
        priceLabel.textColor = .labelColor

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        subscribeButton.target = self
        subscribeButton.action = #selector(handleSubscribe(_:))
        subscribeButton.bezelStyle = .rounded
        subscribeButton.keyEquivalent = "\r"

        restoreButton.target = self
        restoreButton.action = #selector(handleRestore(_:))
        restoreButton.bezelStyle = .rounded

        manageButton.target = self
        manageButton.action = #selector(handleManage(_:))
        manageButton.bezelStyle = .rounded

        helpButton.target = self
        helpButton.action = #selector(handleHelp(_:))
        helpButton.bezelStyle = .rounded

        quitButton.target = self
        quitButton.action = #selector(handleQuit(_:))
        quitButton.bezelStyle = .rounded

        buttonStack.orientation = .vertical
        buttonStack.spacing = 10
        buttonStack.alignment = .centerX
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        [
            subscribeButton,
            restoreButton,
            manageButton,
            helpButton,
            quitButton
        ].forEach(buttonStack.addArrangedSubview(_:))

        let contentStack = NSStackView(views: [
            titleLabel,
            messageLabel,
            priceLabel,
            progressIndicator,
            buttonStack
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])

        render()
    }

    private func render() {
        switch mode {
        case .loading:
            titleLabel.stringValue = "Checking Subscription"
            messageLabel.stringValue = "QuickPreview is verifying your App Store access before opening the player."
            priceLabel.stringValue = ""
            subscribeButton.title = "Start 30-Day Free Trial"
            buttonStack.isHidden = true
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        case .blocked(let accessState, let productDetails):
            titleLabel.stringValue = "Subscribe to QuickPreview"
            messageLabel.stringValue = messageText(for: accessState, productDetails: productDetails)
            if let productDetails {
                priceLabel.stringValue = "\(productDetails.displayName) • \(productDetails.displayPrice) / month"
            } else {
                priceLabel.stringValue = "Monthly subscription with a 30-day free trial"
            }
            subscribeButton.title = "Start 30-Day Free Trial"
            buttonStack.isHidden = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
        }

        subscribeButton.isEnabled = !isBusy && !buttonStack.isHidden
        restoreButton.isEnabled = !isBusy && !buttonStack.isHidden
        manageButton.isEnabled = !isBusy && !buttonStack.isHidden
        helpButton.isEnabled = !isBusy && !buttonStack.isHidden
        quitButton.isEnabled = !isBusy
    }

    private func messageText(
        for accessState: SubscriptionAccessState,
        productDetails: PaywallProductDetails?
    ) -> String {
        let productName = productDetails?.displayName ?? "QuickPreview"

        switch accessState {
        case .expired:
            return "Your \(productName) subscription has expired. Subscribe again to keep using playback and editing features."
        case .refunded:
            return "This purchase was refunded. Subscribe again to continue using \(productName)."
        case .revoked:
            return "This App Store subscription is no longer active for this Apple account."
        case .notEntitled:
            return "Start a monthly subscription to unlock \(productName). Your subscription begins with a 30-day free trial."
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

    @objc
    private func handleSubscribe(_ sender: Any?) {
        _ = sender
        onSubscribe?()
    }

    @objc
    private func handleRestore(_ sender: Any?) {
        _ = sender
        onRestorePurchases?()
    }

    @objc
    private func handleManage(_ sender: Any?) {
        _ = sender
        onManageSubscription?()
    }

    @objc
    private func handleHelp(_ sender: Any?) {
        _ = sender
        onShowHelp?()
    }

    @objc
    private func handleQuit(_ sender: Any?) {
        _ = sender
        onQuit?()
    }
}
