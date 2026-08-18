// Does a blocking Process wait inside an async TaskGroup starve Swift's cooperative pool?
//
// Mimics quality-gate's CheckerRunner: a task group bounded to core count, running a mix of
// CPU-bound checkers (SwiftSyntax parsing) and checkers that shell out to a subprocess.
//
// Variant A ("blocking") is the pattern in QualityGateCore/ProcessRunner.swift today:
//   readDataToEndOfFile() + waitUntilExit(), both blocking calls, made from inside an async task.
// Variant B ("async") is what swift-subprocess — or a continuation-based ProcessRunner — buys you:
//   the task suspends instead of parking a pool thread.
//
// If blocking waits starve the pool, A should be measurably slower than B, and the gap should
// widen as the number of simultaneously-blocked tasks approaches and exceeds the pool width.
//
// Build: swiftc -O -parse-as-library -o starve starve.swift
// Run:   CPU_TASKS=26 SPAWN_TASKS=4 ./starve
import Foundation
import Synchronization

let cores = ProcessInfo.processInfo.activeProcessorCount

func envInt(_ name: String, _ fallback: Int) -> Int {
    ProcessInfo.processInfo.environment[name].flatMap(Int.init) ?? fallback
}

let CPU_TASKS = envInt("CPU_TASKS", 26)
let SPAWN_TASKS = envInt("SPAWN_TASKS", 4)
let CPU_ITERS = envInt("CPU_ITERS", 600_000_000)
let SLEEP = ProcessInfo.processInfo.environment["SLEEP"] ?? "2"
let TRIALS = envInt("TRIALS", 3)

// --- CPU work standing in for a SwiftSyntax checker ---
// The result is funnelled into a global sink so -O cannot eliminate the loop as dead code.
// (An earlier draft discarded the result and the optimizer deleted the work entirely,
//  which made every trial measure nothing but the sleeps.)
let sink = Mutex<Double>(0)

@inline(never)
func cpuWork(_ iterations: Int) -> Double {
    var acc = 0.0
    for i in 0..<iterations { acc += (Double(i) * 1.000001).squareRoot() }
    return acc
}

@inline(never)
func burn(_ iterations: Int) {
    let v = cpuWork(iterations)
    sink.withLock { $0 += v }
}

// --- Variant A: the current pattern — blocking read + blocking wait ---
func blockingSpawn(seconds: String) {
    // Unbounded: this benchmark exists to reproduce the blocking-subprocess pattern and measure the pool starvation it causes; bounding it would erase the experiment.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = [seconds]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    // Unbounded: this benchmark exists to reproduce the blocking-subprocess pattern and measure the pool starvation it causes; bounding it would erase the experiment.
    _ = pipe.fileHandleForReading.readDataToEndOfFile()
    // Unbounded: this benchmark exists to reproduce the blocking-subprocess pattern and measure the pool starvation it causes; bounding it would erase the experiment.
    p.waitUntilExit()
}

// --- Variant B: suspend instead of blocking ---
func asyncSpawn(seconds: String) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        // Unbounded: this benchmark exists to reproduce the blocking-subprocess pattern and measure the pool starvation it causes; bounding it would erase the experiment.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = [seconds]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.terminationHandler = { _ in cont.resume() }
        do { try p.run() } catch { cont.resume() }
    }
}

/// Exactly `SPAWN_TASKS` spawn tasks, spread evenly through `total` so they start early
/// and stay interleaved with CPU work — as they would in checker order.
func taskPlan() -> [Bool] {
    let total = CPU_TASKS + SPAWN_TASKS
    return (0..<total).map { i in
        (i * SPAWN_TASKS) / total != ((i + 1) * SPAWN_TASKS) / total
    }
}

func runTrial(blocking: Bool, plan: [Bool]) async -> Double {
    let start = ContinuousClock.now
    await withTaskGroup(of: Void.self) { group in
        var running = 0
        for isSpawn in plan {
            if running >= cores { await group.next(); running -= 1 }
            group.addTask {
                if isSpawn {
                    if blocking { blockingSpawn(seconds: SLEEP) }
                    else { await asyncSpawn(seconds: SLEEP) }
                } else {
                    burn(CPU_ITERS)
                }
            }
            running += 1
        }
        await group.waitForAll()
    }
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

@main
struct Bench {
    static func main() async {
        let plan = taskPlan()
        let spawns = plan.filter { $0 }.count
        let cpus = plan.count - spawns

        let c0 = ContinuousClock.now
        burn(CPU_ITERS)
        let calib = ContinuousClock.now - c0
        let calibSec = Double(calib.components.seconds)
            + Double(calib.components.attoseconds) / 1e18

        print("cores=\(cores)  pool width=\(cores)")
        print("plan: \(cpus) CPU tasks + \(spawns) spawn tasks (sleep \(SLEEP)s each)")
        print("one CPU task = \(fixed(calibSec, 3))s  (serial CPU total = \(fixed(calibSec * Double(cpus), 1))s)")
        for trial in 1...TRIALS {
            let b = await runTrial(blocking: true, plan: plan)
            let a = await runTrial(blocking: false, plan: plan)
            print("trial \(trial)  blocking=\(fixed(b, 2))s  async=\(fixed(a, 2))s  ratio=\(fixed(b / a, 2))x")
        }
    }
}

/// A fixed-point decimal rendering, locale-independent.
///
/// Not `String(format:)`: that bridges to the C printf ABI, where passing the wrong argument
/// type is a runtime `SIGSEGV` rather than a compile error. `FloatingPointFormatStyle` is
/// locale-aware, and a benchmark whose numbers change separator under a different locale is
/// not comparable across the machines it exists to compare.
func fixed(_ value: Double, _ places: Int) -> String {
    value.formatted(
        .number.precision(.fractionLength(places))
            .grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
}
