//
//  GameSort.swift
//  MeloNX
//
//  Created by Stossy11 on 19/7/2026.
//

import Foundation

enum GameSort: String, Codable, CaseIterable {
    case alphabetical
    case newest
    case none
    
    var displayName: String {
        switch self {
        case .alphabetical:
            return String(localized: "Alphabetical")
        case .newest:
            return String(localized: "Newest")
        case .none:
            return String(localized: "None")
        }
    }
}
