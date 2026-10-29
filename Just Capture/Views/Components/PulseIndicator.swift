import SwiftUI

struct PulseIndicator: View {
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.record)
                .frame(width: 12, height: 12)
                .scaleEffect(isAnimating ? 2.0 : 1.0)
                .opacity(isAnimating ? 0.0 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false), value: isAnimating)
            
            Circle()
                .fill(Theme.record)
                .frame(width: 12, height: 12)
        }
        .onAppear {
            isAnimating = true
        }
    }
}
