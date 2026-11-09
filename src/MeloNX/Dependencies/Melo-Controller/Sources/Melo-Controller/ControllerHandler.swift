//
//  ControllerHandler.swift
//  Melo-Controller
//
//  Created by Stossy11 on 8/3/2026.
//

import SwiftUI

@MainActor
class ControllerHandler: ObservableObject {

    @Published var isPortrait: Bool = false

    func updateOrientation() {
        guard let window = Window.window else { return }
        self.isPortrait = window.bounds.size.height > window.bounds.size.width
    }
}
