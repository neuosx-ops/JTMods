//
//  HNFontManager.swift
//  HarmonyOS Sans Font Manager for HNMod
//

import UIKit
import CoreText

@objc(HNFontManager)
public class HNFontManager: NSObject {

    @objc public static func install() {
        registerFonts()
    }

    private static func registerFonts() {
        let bundle = Bundle(for: HNFontManager.self)
        let fontExtensions = ["ttf", "OTF", "otf", "TTF"]

        var fontURLs: [URL] = []
        for ext in fontExtensions {
            if let urls = bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) {
                fontURLs.append(contentsOf: urls)
            }
        }

        if let fontsDir = bundle.url(forResource: "Fonts", withExtension: nil) {
            if let urls = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil) {
                fontURLs.append(contentsOf: urls)
            }
        }

        for url in fontURLs {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Font registered successfully
            } else if let err = error?.takeRetainedValue() {
                print("HNFontManager: Failed to register font \(url.lastPathComponent): \(err)")
            }
        }
    }
}
