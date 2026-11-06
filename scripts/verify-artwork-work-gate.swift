import Foundation
private actor Counter {
    var active = 0
    var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
    func result() -> (Int, Int) { (active, peak) }
}
@main struct GateCheck {
    static func main() async throws {
        let gate = ArtworkWorkGate(limit: 4), counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    do { try await gate.acquire() } catch { return }
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(3))
                    await counter.leave()
                    await gate.release()
                }
            }
        }
        let (active, peak) = await counter.result()
        precondition(active == 0 && peak <= 4 && peak > 0)
        let single = ArtworkWorkGate(limit: 1)
        try await single.acquire()
        let waiting = Task {
            try await single.acquire()
            await single.release()
        }
        try await Task.sleep(for: .milliseconds(10))
        waiting.cancel()
        do { try await waiting.value; preconditionFailure("cancelled waiter must throw") }
        catch is CancellationError { }
        await single.release()
        try await single.acquire()
        await single.release()
        print("PASS: concurrent workload respects permits; cancelled queued work does not leak a permit")
    }
}
