import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("AIOBS iOS")
                    .font(.title2)
                    .foregroundStyle(.white)

                Text("Camera / WebSocket / SRT")
                    .foregroundStyle(.gray)

                Spacer()

                Text("Transport layer coming next")
                    .foregroundStyle(.gray)

                Spacer()
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}