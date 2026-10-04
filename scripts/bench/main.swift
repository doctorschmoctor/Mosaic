import AppKit
import SwiftUI
import QuartzCore

// Drag benchmark: the demo workspace with four heavy tiles, a tile held and moved in a loop.
// Each step changes the drag, lets SwiftUI process it, lays out and draws, as a frame would.
// Measures main-thread CPU and wall time per step. Fictional data only.

/// Body counters for instrumented variants (incremented by patched sources when present).
enum BenchCounters { nonisolated(unsafe) static var counts = [Int](repeating: 0, count: 8); static func hit(_ index: Int) { counts[index] += 1 } }
extension View { func benchHelp<S: StringProtocol>(_ text: S) -> some View { self } }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicBench-\(UUID())")!, forceDemo: true)
    let images = DemoAssets.imagePaths()
    let heavy = CommandLine.arguments.contains("--heavy")
    if heavy {
        let base = Date().addingTimeInterval(-86400 * 3)
        for index in store.conversations.indices.prefix(8) {
            var messages: [Message] = []
            for n in 0..<120 {
                let withImage = n % 7 == 0 && !images.isEmpty
                let text = withImage ? "" : String(repeating: "Message \(n) about plans for the weekend and what to bring. ", count: 1 + n % 4)
                let attachments = withImage ? [Attachment(id: "img-\(index)-\(n)", path: images[n % images.count], name: "Photo.png", uti: "public.png", pixelWidth: 1200, pixelHeight: 800)] : []
                messages.append(Message(id: "\(index * 1000 + n)", text: text, date: base.addingTimeInterval(Double(n) * 700),
                                        isFromMe: n % 3 == 0, attachments: attachments, isDelivered: true))
            }
            store.conversations[index].messages = messages
        }
    }
    let size = CGSize(width: 1320, height: 860)
    let view = WorkspaceView().environment(store).frame(width: size.width, height: size.height)
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFront(nil)

    func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    func wall() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    func frame() {
        RunLoop.current.run(mode: .default, before: Date())
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        CATransaction.flush()
    }
    func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        let ids = store.workspace.openIDs
        let plan = TileLayout.plan(order: ids, viewport: CGSize(width: 1000, height: 800), layout: store.layout)
        let held = ids[0]
        for _ in 0..<20 { frame() } // warm
        // Idle frames first: the same frame work with nothing changed.
        var idle: [Double] = []
        for _ in 0..<100 { let c0 = cpu(); frame(); idle.append(Double(cpu() - c0) / 1e6) }
        print(String(format: "IDLE cpu_mean=%.3f cpu_p95=%.3f", idle.reduce(0, +) / Double(idle.count), percentile(idle, 0.95)))
        BenchCounters.counts = [Int](repeating: 0, count: 8)
        var cpuTimes: [Double] = [], wallTimes: [Double] = []
        var parts = [Double](repeating: 0, count: 5)
        let steps = 400
        for i in 0..<steps {
            let angle = Double(i) / Double(steps) * .pi * 4
            let translation = CGSize(width: cos(angle) * 320 - 320 + Double(i % 7), height: sin(angle) * 220)
            let c0 = cpu(), w0 = wall()
            store.dragTile(held, translation: translation, plan: plan)
            let c1 = cpu()
            RunLoop.current.run(mode: .default, before: Date())
            let c2 = cpu()
            hosting.layoutSubtreeIfNeeded()
            let c3 = cpu()
            hosting.displayIfNeeded()
            let c4 = cpu()
            CATransaction.flush()
            let c5 = cpu()
            parts[0] += Double(c1 - c0) / 1e6; parts[1] += Double(c2 - c1) / 1e6; parts[2] += Double(c3 - c2) / 1e6
            parts[3] += Double(c4 - c3) / 1e6; parts[4] += Double(c5 - c4) / 1e6
            cpuTimes.append(Double(cpu() - c0) / 1e6)
            wallTimes.append(Double(wall() - w0) / 1e6)
        }
        print(String(format: "PARTS store=%.2f runloop=%.2f layout=%.2f display=%.2f flush=%.2f (ms per step)",
                     parts[0] / Double(steps), parts[1] / Double(steps), parts[2] / Double(steps), parts[3] / Double(steps), parts[4] / Double(steps)))
        print("DRAG frame=\(String(describing: store.tileDrag?.frame))")
        store.finishTileDrag(held)
        frame()
        let total = cpuTimes.reduce(0, +)
        print("COUNTS list=\(BenchCounters.counts[0]) bubble=\(BenchCounters.counts[1]) attachment=\(BenchCounters.counts[2]) tile=\(BenchCounters.counts[3]) workspace=\(BenchCounters.counts[4])")
        print(String(format: "RESULT heavy=%@ steps=%d cpu_mean=%.3f cpu_p50=%.3f cpu_p95=%.3f cpu_max=%.3f wall_mean=%.3f wall_p95=%.3f cpu_total=%.1f",
                     heavy ? "yes" : "no", steps, total / Double(steps), percentile(cpuTimes, 0.5), percentile(cpuTimes, 0.95), cpuTimes.max() ?? 0,
                     wallTimes.reduce(0, +) / Double(steps), percentile(wallTimes, 0.95), total))
        exit(0)
    }
    app.run()
}
