// LaserOverlayView.swift
import SwiftUI

struct LaserOverlayView: View {
    @ObservedObject var viewModel: LaserViewModel
    let screen: NSScreen

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if viewModel.isVisible {
                    LaserCanvasView(viewModel: viewModel, screen: screen)
                }

                // Monitor identification overlay
                if viewModel.showIdentification, let number = viewModel.displayNumber {
                    // Calculate font size based on screen size (same logic as calibration canvas)
                    let fontSize = min(geometry.size.width, geometry.size.height) * 0.6

                    ZStack {
                        // Border glow
                        Rectangle()
                            .strokeBorder(Color.white.opacity(0.5), lineWidth: 8)

                        // Center number
                        Text("\(number)")
                            .font(.system(size: fontSize, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.8))
                            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 0)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color.black.opacity(0.05))
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: viewModel.showIdentification)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
