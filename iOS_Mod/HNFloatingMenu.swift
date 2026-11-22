//
//  HNFloatingMenu.swift
//  Runner - Floating Menu for iOS
//

import UIKit

@_silgen_name("hnmod_bootstrap_anchor")
private func hnmod_bootstrap_anchor()

@objc(HNFloatingMenu)
public class HNFloatingMenu: UIView {
    private static let iconOpacityKey = "hnmod_floating_icon_opacity"

    @objc public static let shared: HNFloatingMenu = {
        // UIView phải được tạo trên main thread
        if Thread.isMainThread {
            hnmod_bootstrap_anchor()
            return HNFloatingMenu()
        }
        return DispatchQueue.main.sync {
            hnmod_bootstrap_anchor()
            return HNFloatingMenu()
        }
    }()

    @objc public static func start() {
        HNModManager.start()
        // Đảm bảo nút luôn được tạo và gắn vào window sau khi start
        DispatchQueue.main.async {
            HNFloatingMenu.shared.attachToWindow()
        }
    }

    private var floatingButton: UIButton!

    /// Đã đặt vị trí mặc định lần đầu chưa (tránh reset vị trí user đã kéo)
    private var hasPlacedInitially = false
    /// Tránh tạo nhiều vòng retry song song khi chưa có window
    private var isRetryingAttach = false

    private override init(frame: CGRect) {
        super.init(frame: CGRect(x: UIScreen.main.bounds.width - 60, y: 150, width: 44, height: 44))
        setupFloatingButton()
        observeWindowChanges()
        attachToWindow()   // gắn ngay khi khởi tạo, không chờ notification
    }

    private func observeWindowChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: UIWindow.didBecomeVisibleNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: UIWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleWindowNotification() {
        attachToWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupFloatingButton() {
        let savedOpacity = UserDefaults.standard.object(forKey: Self.iconOpacityKey) as? Double ?? 1.0
        alpha = CGFloat(savedOpacity)
        self.layer.cornerRadius = 22
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOpacity = 0.3
        self.layer.shadowOffset = CGSize(width: 0, height: 2)
        self.layer.shadowRadius = 4
        self.backgroundColor = .systemRed

        floatingButton = UIButton(type: .custom)
        floatingButton.frame = self.bounds
        floatingButton.setTitle("HN", for: .normal)
        floatingButton.setTitleColor(.white, for: .normal)
        floatingButton.titleLabel?.font = UIFont(name: "HarmonyOS_Sans_Bold", size: 16) ?? UIFont.boldSystemFont(ofSize: 16)
        floatingButton.addTarget(self, action: #selector(floatingButtonTapped), for: .touchUpInside)

        self.addSubview(floatingButton)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        self.addGestureRecognizer(panGesture)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self.superview)
        self.center = CGPoint(x: self.center.x + translation.x, y: self.center.y + translation.y)
        gesture.setTranslation(.zero, in: self.superview)
    }

    @objc public func attachToWindow() {
        if Thread.isMainThread {
            doAttach()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.doAttach()
            }
        }
    }

    private func findTargetWindow() -> UIWindow? {
        let sceneWindows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }

        if let key = sceneWindows.first(where: { $0.isKeyWindow }) { return key }
        if let visible = sceneWindows.first(where: { !$0.isHidden }) { return visible }
        if let first = sceneWindows.first { return first }

        let legacy = UIApplication.shared.windows
        if let key = legacy.first(where: { $0.isKeyWindow }) { return key }
        if let visible = legacy.first(where: { !$0.isHidden }) { return visible }
        return legacy.first
    }

    private func doAttach() {
        guard let window = findTargetWindow() else {
            // Chưa có window -> thử lại sau (chỉ một vòng retry tại một thời điểm)
            guard !isRetryingAttach else { return }
            isRetryingAttach = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.isRetryingAttach = false
                self.doAttach()
            }
            return
        }

        // Gắn lại nếu đang ở window khác (hoặc chưa có superview)
        if self.superview !== window {
            self.removeFromSuperview()
            window.addSubview(self)
        }

        if !hasPlacedInitially {
            self.frame.origin = CGPoint(x: window.bounds.width - 60, y: 150)
            hasPlacedInitially = true
        } else {
            clampInside(window)
        }

        window.bringSubviewToFront(self)
    }

    /// Giữ nút trong màn hình (sau khi xoay / đổi kích thước) mà không reset vị trí đã kéo
    private func clampInside(_ window: UIWindow) {
        let bounds = window.bounds
        let size = self.frame.size
        var origin = self.frame.origin
        origin.x = min(max(origin.x, 0), max(bounds.width - size.width, 0))
        origin.y = min(max(origin.y, 0), max(bounds.height - size.height, 0))
        if origin != self.frame.origin {
            self.frame.origin = origin
        }
    }

    @objc private func floatingButtonTapped() {
        showQuickMenu()
    }

    private func locationMenuTitle() -> String {
        return "Lưu Vị Trí 🎯"
    }

    private func showQuickMenu() {
        guard let topVC = getTopViewController() else { return }
        let menu = HNQuickMenuViewController()
        menu.modalPresentationStyle = .overFullScreen
        topVC.present(menu, animated: true, completion: nil)
    }

    @objc public func showManualCoordinateInputFrom(_ topVC: UIViewController) {
        let alert = UIAlertController(
            title: "Manual Coordinates",
            message: "Paste coordinates: 11°44'05.4\"N 108°21'41.0\"E",
            preferredStyle: .alert
        )

        alert.addTextField { field in
            field.placeholder = "11°44'05.4\"N 108°21'41.0\"E"
            field.keyboardType = .default
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
        }

        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        let saveAction = UIAlertAction(title: "Save", style: .default) { _ in
            guard let coordinateText = alert.textFields?.first?.text,
                  let coordinates = HNLocationHook.parseDMSCoordinates(coordinateText) else {
                let errorAlert = UIAlertController(
                    title: "Invalid Coordinates",
                    message: "Please use format: 11°44'05.4\"N 108°21'41.0\"E",
                    preferredStyle: .alert
                )
                errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                topVC.present(errorAlert, animated: true)
                return
            }

            HNLocationHook.savedLatitude = coordinates.latitude
            HNLocationHook.savedLongitude = coordinates.longitude

            let successAlert = UIAlertController(
                title: "Saved ✅",
                message: String(format: "Latitude: %.6f\nLongitude: %.6f", coordinates.latitude, coordinates.longitude),
                preferredStyle: .alert
            )
            successAlert.addAction(UIAlertAction(title: "OK", style: .default))
            topVC.present(successAlert, animated: true)
        }

        alert.addAction(cancelAction)
        alert.addAction(saveAction)
        topVC.present(alert, animated: true)
    }

    @objc public func showThemeMenuFrom(_ topVC: UIViewController, completion: (() -> Void)? = nil) {
        let alert = UIAlertController(title: "Theme Mode", message: nil, preferredStyle: .actionSheet)
        applyHarmonyOSFont(to: alert)

        for mode in HNThemeMode.allCases {
            let title = mode.title + (HNThemeManager.mode == mode ? " ✓" : "")
            alert.addAction(menuAction(title: title, style: .default) { _ in
                HNThemeManager.mode = mode
                completion?()
            })
        }
        alert.addAction(menuAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = self.bounds
        }
        topVC.present(alert, animated: true)
    }

    @objc public func showIconOpacityMenuFrom(_ topVC: UIViewController) {
        let alert = UIAlertController(title: "Icon Opacity", message: nil, preferredStyle: .actionSheet)
        applyHarmonyOSFont(to: alert)

        let options: [(title: String, opacity: Double)] = [
            ("2%", 0.02),
            ("25%", 0.25),
            ("50%", 0.5),
            ("75%", 0.75),
            ("100%", 1.0)
        ]
        for option in options {
            let savedOpacity = UserDefaults.standard.object(forKey: Self.iconOpacityKey) as? Double ?? 1.0
            let title = option.title + (savedOpacity == option.opacity ? " ✓" : "")
            alert.addAction(menuAction(title: title, style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.alpha = CGFloat(option.opacity)
                UserDefaults.standard.set(option.opacity, forKey: Self.iconOpacityKey)
            })
        }
        alert.addAction(menuAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = self.bounds
        }
        topVC.present(alert, animated: true)
    }

    @objc public func getTopWindowController() -> UIViewController? {
        return getTopViewController()
    }

    private func menuAction(
        title: String,
        style: UIAlertAction.Style,
        handler: ((UIAlertAction) -> Void)? = nil
    ) -> UIAlertAction {
        let action = UIAlertAction(title: title, style: style, handler: handler)
        let font = UIFont(name: "HarmonyOS_Sans_Medium", size: 17) ?? UIFont.systemFont(ofSize: 17)
        let attrTitle = NSAttributedString(string: title, attributes: [.font: font])
        if action.responds(to: NSSelectorFromString("setAttributedTitle:")) {
            action.setValue(attrTitle, forKey: "attributedTitle")
        } else if action.responds(to: NSSelectorFromString("set_titleTextFont:")) {
            action.setValue(font, forKey: "_titleTextFont")
        }
        return action
    }

    private func applyHarmonyOSFont(to alert: UIAlertController) {
        guard let title = alert.title else { return }
        let font = UIFont(name: "HarmonyOS_Sans_Bold", size: 18) ?? UIFont.boldSystemFont(ofSize: 18)
        let titleAttr = NSAttributedString(string: title, attributes: [.font: font])
        if alert.responds(to: NSSelectorFromString("setAttributedTitle:")) {
            alert.setValue(titleAttr, forKey: "attributedTitle")
        }
    }


    private func showFakeCallHistoryInputDialog() {
        guard let topVC = getTopViewController() else { return }
        HNFakeCallHistoryViewController.presentInputDialog(from: topVC)
    }

    // MARK: - Bank Config Dialog

    @objc public func showBankConfigDialog() {
        guard let topVC = getTopViewController() else { return }
        HNBankConfig.presentConfiguration(from: topVC)
    }

    private func getTopViewController() -> UIViewController? {
        guard let window = findTargetWindow(),
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}