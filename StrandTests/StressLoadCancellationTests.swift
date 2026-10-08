import XCTest
@testable import Strand

@MainActor
final class StressLoadCancellationTests: XCTestCase {
    func testSuccessfulReadAndTwoPhaseOrderStayIntact() async {
        var phases: [Int] = []
        if let core = await StressLoadCancellation.read({ 21 }) { phases.append(core) }
        if let lenses = await StressLoadCancellation.read({ 34 }) { phases.append(lenses) }
        XCTAssertEqual(phases, [21, 34])
    }

    func testSuccessfulAbsentValueIsNotCancellation() async {
        let result: Int?? = await StressLoadCancellation.read({ nil as Int? })
        XCTAssertEqual(result, .some(.none))
    }

    func testAlreadyCancelledLoadDoesNotStartARead() async {
        var reads = 0
        let task = Task { @MainActor in
            await StressLoadCancellation.read {
                reads += 1
                return 7
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(reads, 0)
    }

    func testLateCancelledReadCannotReplaceFreshState() async {
        let gate = StressFixtureSuspension()
        var published: [String] = []
        let old = Task { @MainActor in
            if let value = await StressLoadCancellation.read({
                await gate.holdStressFixture()
                return "old"
            }) { published.append(value) }
        }
        await gate.waitForStressFixture()
        old.cancel()
        if let fresh = await StressLoadCancellation.read({ "fresh" }) { published.append(fresh) }
        await gate.releaseStressFixture()
        await old.value
        XCTAssertEqual(published, ["fresh"])
    }

    func testCancelledCoreDoesNotStartAdvancedWork() async {
        let gate = StressFixtureSuspension()
        var advancedReads = 0
        var published: [Int] = []
        let task = Task { @MainActor in
            guard let core = await StressLoadCancellation.read({
                await gate.holdStressFixture()
                return 1
            }) else { return }
            published.append(core)
            if let lenses = await StressLoadCancellation.read({
                advancedReads += 1
                return 2
            }) { published.append(lenses) }
        }
        await gate.waitForStressFixture()
        task.cancel()
        await gate.releaseStressFixture()
        await task.value
        XCTAssertEqual(published, [])
        XCTAssertEqual(advancedReads, 0)
    }

    func testLateAdvancedReadCannotRestoreOldLenses() async {
        let gate = StressFixtureSuspension()
        var published: [String] = []
        let old = Task { @MainActor in
            guard let core = await StressLoadCancellation.read({ "old-core" }) else { return }
            published.append(core)
            if let lenses = await StressLoadCancellation.read({
                await gate.holdStressFixture()
                return "old-lenses"
            }) { published.append(lenses) }
        }
        await gate.waitForStressFixture()
        old.cancel()
        if let fresh = await StressLoadCancellation.read({ "fresh-core" }) { published.append(fresh) }
        await gate.releaseStressFixture()
        await old.value
        XCTAssertEqual(published, ["old-core", "fresh-core"])
    }
}

/// Deliberately ignores task cancellation, like a detached calculation or a completed database read.
private actor StressFixtureSuspension {
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var started = false

    func holdStressFixture() async {
        await withCheckedContinuation { continuation in
            held = continuation
            started = true
            waiting?.resume()
            waiting = nil
        }
    }

    func waitForStressFixture() async {
        if started { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func releaseStressFixture() {
        held?.resume()
        held = nil
    }
}
