//
//  HNQuickMenuViewController.swift
//  Runner - Custom Bottom Sheet Quick Menu with HarmonyOS Font & English Labels
//

import UIKit

@objc(HNQuickMenuViewController)
public class HNQuickMenuViewController: UIViewController, UIGestureRecognizerDelegate {

    private let containerView = UIView()
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)

        containerView.backgroundColor = UIColor.secondarySystemBackground
        containerView.layer.cornerRadius = 24
        containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        let titleLabel = UILabel()
        titleLabel.text = "NeuOSX Menu"
        titleLabel.font = UIFont(name: "HarmonyOS_Sans_Bold", size: 18) ?? UIFont.boldSystemFont(ofSize: 18)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(scrollView)

        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 520),

            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        populateButtons()

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissModal))
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    private func addButton(title: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = UIFont(name: "HarmonyOS_Sans_Medium", size: 16) ?? UIFont.systemFont(ofSize: 16, weight: .medium)
        btn.setTitleColor(isDestructive ? .systemRed : .label, for: .normal)
        btn.backgroundColor = UIColor.systemBackground
        btn.layer.cornerRadius = 12
        btn.contentHorizontalAlignment = .left
        btn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        let actionWrapper = ActionWrapper(action: action)
        objc_setAssociatedObject(btn, "btnAction", actionWrapper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        btn.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)

        stackView.addArrangedSubview(btn)
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        if let wrapper = objc_getAssociatedObject(sender, "btnAction") as? ActionWrapper {
            dismiss(animated: true) {
                wrapper.action()
            }
        }
    }

    @objc private func dismissModal() {
        dismiss(animated: true)
    }

    private func populateButtons() {
        addButton(title: "⏰ Check-In") { [weak self] in
            guard let top = self else { return }
            HNAttendanceHook.performAutomaticClock(clockType: 1) { success, msg in
                let alertResult = UIAlertController(title: success ? "Success ✅" : "Failed ❌", message: msg, preferredStyle: .alert)
                alertResult.addAction(UIAlertAction(title: "OK", style: .default))
                top.present(alertResult, animated: true)
            }
        }

        addButton(title: "⏰ Check-Out") { [weak self] in
            guard let top = self else { return }
            HNAttendanceHook.performAutomaticClock(clockType: 2) { success, msg in
                let alertResult = UIAlertController(title: success ? "Success ✅" : "Failed ❌", message: msg, preferredStyle: .alert)
                alertResult.addAction(UIAlertAction(title: "OK", style: .default))
                top.present(alertResult, animated: true)
            }
        }

        addButton(title: "👤 Face Photo") { [weak self] in
            guard let top = self else { return }
            HNPickerHelper.showPicker(in: top) { image in
                if let img = image {
                    HNAttendanceHook.saveFacePhoto(img)
                    let successAlert = UIAlertController(title: "Saved ✅", message: "Face photo updated.", preferredStyle: .alert)
                    successAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    top.present(successAlert, animated: true)
                } else {
                    let errAlert = UIAlertController(title: "Error", message: "No image selected.", preferredStyle: .alert)
                    errAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    top.present(errAlert, animated: true)
                }
            }
        }

        addButton(title: "🛠️ STK Config") { [weak self] in
            guard let top = self else { return }
            HNBankConfig.presentConfiguration(from: top)
        }

        addButton(title: "🕒 Call Log") { [weak self] in
            guard let top = self else { return }
            HNFakeCallHistoryViewController.presentInputDialog(from: top)
        }

        let savedLocTitle = HNLocationHook.savedLatitude != 0 ? "🎯 Save Location (Saved)" : "🎯 Save Location"
        addButton(title: savedLocTitle) { [weak self] in
            guard let top = self else { return }
            HNLocationHook.shared.captureAndSaveCurrentLocation(from: top)
        }

        addButton(title: "📍 Manual Coordinates") { [weak self] in
            guard let top = self else { return }
            HNFloatingMenu.shared.showManualCoordinateInputFrom(top)
        }

        if let googleMapsURL = HNLocationHook.googleMapsURL {
            addButton(title: "🗺️ Google Maps") {
                UIApplication.shared.open(googleMapsURL, options: [:], completionHandler: nil)
            }
        }

        let fakeLocText = HNLocationHook.isFakeLocationEnabled ? "📍 Fake Location: ON" : "📍 Fake Location: OFF"
        addButton(title: fakeLocText) { [weak self] in
            HNLocationHook.isFakeLocationEnabled.toggle()
            self?.reloadMenu()
        }

        let fakeCallText = HNURLProtocol.isFakeCallEnabled ? "📞 Fake Call: ON" : "📞 Fake Call: OFF"
        addButton(title: fakeCallText) { [weak self] in
            HNURLProtocol.isFakeCallEnabled.toggle()
            self?.reloadMenu()
        }

        addButton(title: "🎨 Theme: \(HNThemeManager.mode.title)") { [weak self] in
            guard let top = self else { return }
            HNFloatingMenu.shared.showThemeMenuFrom(top) {
                self?.reloadMenu()
            }
        }

        addButton(title: "❤️ Blur Icon") { [weak self] in
            guard let top = self else { return }
            HNFloatingMenu.shared.showIconOpacityMenuFrom(top)
        }

        addButton(title: "❌ Cancel", isDestructive: true) {
            // Dismiss
        }
    }

    private func reloadMenu() {
        dismiss(animated: false) {
            if let top = HNFloatingMenu.shared.getTopWindowController() {
                let menu = HNQuickMenuViewController()
                menu.modalPresentationStyle = .overFullScreen
                top.present(menu, animated: false)
            }
        }
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return touch.view === view
    }
}

private final class ActionWrapper: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }
}
