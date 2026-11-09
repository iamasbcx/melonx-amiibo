//
//  Window.swift
//  Melo-Controller
//
//  Created by Stossy11 on 8/3/2026.
//

import UIKit

@MainActor
struct Window {
    static var window: UIWindow? {
        UIApplication.shared.windows.filter {$0.isKeyWindow}.first
    }
}
