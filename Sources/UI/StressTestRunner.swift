import Foundation

// MARK: - StressTestRunner
//
// A short CPU-bound loop that the user can fire from the menu to
// deliberately drive the system load up. Useful for:
//   1. Verifying the alert pipeline end-to-end (does the temperature
//      actually rise when the CPU is busy? does the fan spin up?)
//   2. Watching the charts respond to a sudden load change
//   3. Comparing the same workload today vs a few weeks from now
//      (the whole point of the app)
//
// We don't touch any of the app's other state — the Sampler keeps
// running on its own timer, so you'll see the temperature rise in
// real time in the popover/charts.

enum StressTestRunner {

    /// Burn CPU on N worker threads for `duration` seconds. Blocks
    /// the calling thread, so callers should run it on a background
    /// queue.
    static func run(durationSeconds: TimeInterval = 30,
                    workerCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        let end = Date().addingTimeInterval(durationSeconds)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        for _ in 0..<workerCount {
            group.enter()
            queue.async {
                var acc: Double = 1.0
                while Date() < end {
                    // Tight loop with no syscalls — saturates the FPU.
                    acc = acc * 1.0000001 + 0.0000001
                }
                _ = acc
                group.leave()
            }
        }
        group.wait()
    }
}
