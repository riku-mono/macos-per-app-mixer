//
//  MixerApp.swift
//  Mixer
//

import SwiftUI
 
@main
struct MixerApp: App {
    @State private var model = MixerModel()
 
    var body: some Scene {
        // メニューバーにアイコンを置き、クリックでパネルを開く
        MenuBarExtra("Mixer", systemImage: "slider.horizontal.3") {
            MixerView(model: model)
        }
        .menuBarExtraStyle(.window) // メニューではなく小さなウィンドウとして表示
    }
}
 
