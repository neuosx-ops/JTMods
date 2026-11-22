//
//  HNModManager.swift
//  Central startup and feature registration
//

import UIKit

@objc(HNModManager)
public final class HNModManager: NSObject {
    private static var hasStarted = false

    @objc public static func start() {
        DispatchQueue.main.async {
            guard !hasStarted else { return }
            hasStarted = true
            HNFontManager.install()
            HNLocationHook.install()
            HNURLProtocol.startIntercepting()
            HNPresentHook.install()
            HNAlertHook.install()
            HNMessageHook.install()
            HNMoneyHook.install()
            HNSMSOpenHook.install()
            HNThemeManager.install()
            HNJTSheetHook.installJTSheetHook()
            HNDeliveryDetailHook.install()
            HNCameraHook.setup()
            HNFloatingMenu.shared.attachToWindow()
        }
    }
}