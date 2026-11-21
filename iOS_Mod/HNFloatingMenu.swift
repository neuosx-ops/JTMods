//
//  HNFloatingMenu.swift
//  Runner - Floating Menu for iOS
//

import UIKit

@_silgen_name("hnmod_bootstrap_anchor")
private func hnmod_bootstrap_anchor()

/// Window đặc biệt tự động cho phép touch xuyên qua (pass-through) trừ những view con trực tiếp có tương tác
@objc(HNPassThroughWindow)
public final class HNPassThroughWindow: UIWindow {
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        // Nếu điểm chạm rơi vào chính Window hoặc View nền của rootViewController, trả về nil để touch xuyên qua app bên dưới
        if hitView === self || hitView === rootViewController?.view {
            return nil
        }
        return hitView
    }
}

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
    private var overlayWindow: HNPassThroughWindow?
    private var isRetryingAttach = false

    /// Đã đặt vị trí mặc định lần đầu chưa (tránh reset vị trí user đã kéo)
    private var hasPlacedInitially = false

    private override init(frame: CGRect) {
        let initialBounds = UIScreen.main.bounds
        let width = initialBounds.width > 0 ? initialBounds.width : 375
        super.init(frame: CGRect(x: width - 60, y: 150, width: 44, height: 44))
        setupFloatingButton()
        observeWindowChanges()
        DispatchQueue.main.async { [weak self] in
            self?.attachToWindow()
        }
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
        alpha = CGFloat(max(0.1, savedOpacity))
        self.layer.cornerRadius = 22
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOpacity = 0.3
        self.layer.shadowOffset = CGSize(width: 0, height: 2)
        self.layer.shadowRadius = 4
        self.backgroundColor = .systemRed

        floatingButton = UIButton(type: .custom)
        floatingButton.frame = self.bounds
        floatingButton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        floatingButton.setTitle("HN", for: .normal)
        floatingButton.setTitleColor(.white, for: .normal)
        floatingButton.titleLabel?.font = UIFont(name: "HarmonyOS_Sans_Bold", size: 16) ?? UIFont.boldSystemFont(ofSize: 16)
        floatingButton.addTarget(self, action: #selector(floatingButtonTapped), for: .touchUpInside)

        self.addSubview(floatingButton)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        self.addGestureRecognizer(panGesture)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let containerView = self.superview else { return }
        let translation = gesture.translation(in: containerView)
        self.center = CGPoint(x: self.center.x + translation.x, y: self.center.y + translation.y)
        gesture.setTranslation(.zero, in: containerView)

        if gesture.state == .ended || gesture.state == .cancelled {
            if let window = overlayWindow ?? self.window {
                clampInside(window)
            }
        }
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

    /// Tìm window của app để lấy rootViewController phục vụ cho việc present Alert/Sheet
    private func findAppWindow() -> UIWindow? {
        let sceneWindows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { $0 !== overlayWindow }

        let candidates = sceneWindows.filter { window in
            !window.isHidden && window.windowLevel == .normal && window.rootViewController != nil
        }

        if let key = candidates.first(where: { $0.isKeyWindow }) { return key }
        if let last = candidates.last { return last }

        // Fallback cho app không dùng UIScene
        let legacy = UIApplication.shared.windows.filter { $0 !== overlayWindow && !$0.isHidden && $0.windowLevel == .normal && $0.rootViewController != nil }
        return legacy.first(where: { $0.isKeyWindow })
            ?? legacy.last
            ?? sceneWindows.last
            ?? UIApplication.shared.windows.first(where: { $0 !== overlayWindow && $0.rootViewController != nil })
    }

    private func doAttach() {
        guard Thread.isMainThread else { return }

        guard let appWindow = findAppWindow() else {
            guard !isRetryingAttach else { return }
            isRetryingAttach = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.isRetryingAttach = false
                self.doAttach()
            }
            return
        }

        var scene: UIWindowScene? = nil
        if #available(iOS 13.0, *) {
            scene = appWindow.windowScene
        }

        if overlayWindow == nil {
            let win: HNPassThroughWindow
            if #available(iOS 13.0, *), let targetScene = scene {
                win = HNPassThroughWindow(windowScene: targetScene)
            } else {
                win = HNPassThroughWindow(frame: appWindow.bounds)
            }
            win.windowLevel = UIWindow.Level.statusBar + 100
            win.backgroundColor = .clear

            let rootVC = UIViewController()
            rootVC.view.backgroundColor = .clear
            rootVC.view.isUserInteractionEnabled = true
            win.rootViewController = rootVC

            rootVC.view.addSubview(self)
            win.isHidden = false
            self.overlayWindow = win
        } else {
            if #available(iOS 13.0, *), let targetScene = scene, overlayWindow?.windowScene !== targetScene {
                overlayWindow?.windowScene = targetScene
            }
            overlayWindow?.isHidden = false
        }

        if let win = overlayWindow {
            win.rootViewController?.view.bringSubviewToFront(self)
            if !hasPlacedInitially || self.frame.origin == .zero {
                let winWidth = win.bounds.width > 0 ? win.bounds.width : appWindow.bounds.width
                self.frame.origin = CGPoint(x: max(10, winWidth - 60), y: 150)
                hasPlacedInitially = true
            } else {
                clampInside(win)
            }
        }
    }

    /// Giữ nút trong màn hình (sau khi xoay / đổi kích thước) mà không reset vị trí đã kéo
    private func clampInside(_ window: UIWindow) {
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
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
        return "Lưu Vị Trí Hiện Tại 🎯"
    }

    private func showQuickMenu() {
        guard let topVC = getTopViewController() else { return }

        let alert = UIAlertController(title: "HN MOD", message: nil, preferredStyle: .actionSheet)
        applyFuturaFont(to: alert)

        let fakeCallTitle = HNURLProtocol.isFakeCallEnabled ? "Fake Call ✅" : "Fake Call ❌"
        alert.addAction(menuAction(title: fakeCallTitle, style: .default) { [weak self] _ in
            HNURLProtocol.isFakeCallEnabled.toggle()
            self?.showQuickMenu()
        })

        let fakeLocTitle = HNLocationHook.isFakeLocationEnabled ? "Fake Location 📍 ✅" : "Fake Location 📍 ❌"
        alert.addAction(menuAction(title: fakeLocTitle, style: .default) { [weak self] _ in
            HNLocationHook.isFakeLocationEnabled.toggle()
            self?.showQuickMenu()
        })

        let savedLocationTitle = locationMenuTitle()
        alert.addAction(menuAction(title: savedLocationTitle, style: .default) { [weak self] _ in
            guard let top = self?.getTopViewController() else { return }
            HNLocationHook.shared.captureAndSaveCurrentLocation(from: top)
        })

        alert.addAction(menuAction(title: "Nhập Tọa Độ Thủ Công 📍", style: .default) { [weak self] _ in
            self?.showManualCoordinateInput()
        })

        if let googleMapsURL = HNLocationHook.googleMapsURL {
            alert.addAction(menuAction(title: "Mở Google Maps 🗺️", style: .default) { _ in
                UIApplication.shared.open(googleMapsURL, options: [:], completionHandler: nil)
            })
        }

        alert.addAction(menuAction(title: "Blur Icon ❤️", style: .default) { [weak self] _ in
            self?.showIconOpacityMenu()
        })

        alert.addAction(menuAction(title: "Giao diện: \(HNThemeManager.mode.title) 🎨", style: .default) { [weak self] _ in
            self?.showThemeMenu()
        })


        alert.addAction(menuAction(title: "Call Log Screen 🕒", style: .default) { [weak self] _ in
            self?.showFakeCallHistoryInputDialog()
        })

        alert.addAction(menuAction(title: "Config STK 🛠️", style: .default) { [weak self] _ in
            self?.showBankConfigDialog()
        })
        alert.addAction(menuAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = self.bounds
        }

        topVC.present(alert, animated: true)
    }

    private func showThemeMenu() {
        guard let topVC = getTopViewController() else { return }
        let alert = UIAlertController(title: "Giao diện", message: nil, preferredStyle: .actionSheet)
        applyFuturaFont(to: alert)

        for mode in HNThemeMode.allCases {
            let title = mode.title + (HNThemeManager.mode == mode ? " ✓" : "")
            alert.addAction(menuAction(title: title, style: .default) { _ in
                HNThemeManager.mode = mode
            })
        }
        alert.addAction(menuAction(title: "Huỷ", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = self.bounds
        }
        topVC.present(alert, animated: true)
    }

    private func showManualCoordinateInput() {
        guard let topVC = getTopViewController() else { return }
        let alert = UIAlertController(
            title: "Nhập Tọa Độ",
            message: "Dán toàn bộ tọa độ: 11°44'05.4\"N 108°21'41.0\"E",
            preferredStyle: .alert
        )

        alert.addTextField { field in
            field.placeholder = "11°44'05.4\"N 108°21'41.0\"E"
            field.keyboardType = .default
            field.smartQuotesType = .no      // không tự đổi ' " thành ’ ”
            field.smartDashesType = .no
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
        }

        let cancelAction = UIAlertAction(title: "Huỷ", style: .cancel)
        let saveAction = UIAlertAction(title: "Lưu", style: .default) { _ in
            guard let coordinateText = alert.textFields?.first?.text,
                  let coordinates = HNLocationHook.parseDMSCoordinates(coordinateText) else {
                let errorAlert = UIAlertController(
                    title: "Tọa Độ Không Hợp Lệ",
                    message: "Vui lòng nhập đúng định dạng: 11°44'05.4\"N 108°21'41.0\"E",
                    preferredStyle: .alert
                )
                errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                topVC.present(errorAlert, animated: true)
                return
            }

            HNLocationHook.savedLatitude = coordinates.latitude
            HNLocationHook.savedLongitude = coordinates.longitude

            let successAlert = UIAlertController(
                title: "Đã Lưu Tọa Độ ✅",
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

    private func showIconOpacityMenu() {
        guard let topVC = getTopViewController() else { return }
        let alert = UIAlertController(title: "Blur Icon", message: nil, preferredStyle: .actionSheet)
        applyFuturaFont(to: alert)

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

    private func menuAction(
        title: String,
        style: UIAlertAction.Style,
        handler: ((UIAlertAction) -> Void)? = nil
    ) -> UIAlertAction {
        let action = UIAlertAction(title: title, style: style, handler: handler)
        let font = UIFont(name: "HarmonyOS_Sans_Medium", size: 17) ?? UIFont.systemFont(ofSize: 17)
        if action.responds(to: NSSelectorFromString("set_titleTextFont:")) {
            action.setValue(font, forKey: "_titleTextFont")
        }
        return action
    }

    private func applyFuturaFont(to alert: UIAlertController) {
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
        guard let window = findAppWindow(),
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}