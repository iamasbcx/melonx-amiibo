//
//  RamLimitTestView.swift
//  MeloNX
//
//  Created by Stossy11 on 30/7/2026.
//

import SwiftUI

struct RamLimitTestView: View {
    @StateObject var viewModel: MemoryLimitManager = .init()
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        Text(viewModel.formatMemorySize())
                            .font(.largeTitle)
                        Spacer()
                    }
                } footer: {
                        Text(LocalizedStringKey("This is designed to test the memory limit of your device by allocating ram until the app crashes, once it crashes going into this menu again shows the result."))
                }
                
                Section {
                    Button(viewModel.started ? String(localized: "Stop") : String(localized: "Start")) {
                        guard !viewModel.started else { viewModel.stop(); return }
                        
                        viewModel.testRAMLimit()
                    }
                } footer: {
                    Text(LocalizedStringKey("Please do not close the app during this process or else you may get an invalid result."))
                }
            }
            .navigationTitle(Text(LocalizedStringKey("Memory Limit Tester")))
            .modifier(HiddenScrollBackground())
            .themedBackground()
        }
    }
}
