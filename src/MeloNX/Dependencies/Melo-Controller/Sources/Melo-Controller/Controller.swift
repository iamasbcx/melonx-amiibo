//
//  Controller.swift
//  Melo-Controller
//
//  Created by Stossy11 on 8/3/2026.
//

import SwiftUI

public protocol Controller: ObservableObject {
    func buttonPressed(_ button: VirtualControllerButton)
    func buttonReleased(_ button: VirtualControllerButton)

    func joystickMoved(position: CGPoint, right: Bool)
}
