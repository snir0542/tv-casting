import ReplayKit
import SwiftUI

@main
struct TVMirrorApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var status = ""

    var body: some View {
        VStack(spacing: 24) {
            Text("TV Mirror").font(.largeTitle.bold())

            Text("1. בדיקת חיבור (בפעם הראשונה תאשר גישה לרשת המקומית)\n2. לחיצה על העיגול ← Start Broadcast\n3. בפעם הראשונה הטלוויזיה תשאל אם לאפשר את המכשיר – אשר בשלט")
                .multilineTextAlignment(.center)

            Button("בדיקת חיבור לטלוויזיה") {
                Task {
                    status = "בודק..."
                    if let dlna = DLNAController() {
                        status = await dlna.check()
                    } else {
                        status = "❌ tvControlURL לא הוגדר ב-Config.swift"
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            Text(status).font(.footnote)

            BroadcastPicker().frame(width: 80, height: 80)

            Text(Config.tvControlURL).font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// The system "start broadcast" button, pre-selecting our extension.
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        picker.showsMicrophoneButton = false
        // Read the bundle id at runtime: sideloading tools may rename it.
        if let plugins = Bundle.main.builtInPlugInsURL,
           let appex = try? FileManager.default
               .contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
               .first(where: { $0.pathExtension == "appex" }),
           let id = Bundle(url: appex)?.bundleIdentifier {
            picker.preferredExtension = id
        }
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
