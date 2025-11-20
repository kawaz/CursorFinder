// LaserGuideApp.swift
import SwiftUI

@main
struct LaserGuideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
        }
    }
}
