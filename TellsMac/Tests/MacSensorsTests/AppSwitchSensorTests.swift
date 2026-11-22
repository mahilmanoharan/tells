import Foundation
import Synchronization
import Testing
import TellsCore
@testable import MacSensors

private final class FakeAppSource: AppActivationSource {
    let stops = Mutex(0)
    func start(handler: @escaping @Sendable (AppActivation) -> Void) {}
    func stop() { stops.withLock { $0 += 1 } }
    let front = Mutex<AppActivation?>(nil)
    func frontmost() -> AppActivation? { front.withLock { $0 } }
}

private func makeAppSwitchSensor(source: FakeAppSource = FakeAppSource()) -> AppSwitchSensor {
    AppSwitchSensor(source: source, now: { Date(timeIntervalSince1970: 100) })
}

private func activation(_ category: String?, pid: Int32, isTells: Bool = false) -> AppActivation {
    AppActivation(categoryType: category, processID: pid, isTells: isTells)
}

private func collect(_ sensor: AppSwitchSensor, _ stream: AsyncStream<SensorSample>) async -> [SensorSample] {
    await sensor.stop()
    var samples: [SensorSample] = []
    for await sample in stream { samples.append(sample) }
    return samples
}

struct AppSwitchSensorTests {
    @Test func declaresItself() async {
        let sensor = makeAppSwitchSensor()
        #expect(sensor.id == .appswitch)
        #expect(sensor.permission == nil)
        #expect(!sensor.usesPrivateAPI)
        #expect(await sensor.availability() == .available)
    }

    @Test func yieldsOneSampleForEachRealChange() async throws {
        let sensor = makeAppSwitchSensor()
        let stream = try sensor.start()
        sensor.handle(activation("public.app-category.developer-tools", pid: 1))
        sensor.handle(activation("public.app-category.developer-tools", pid: 1))   // same app: no sample
        sensor.handle(activation("public.app-category.social-networking", pid: 2))
        sensor.handle(activation("public.app-category.developer-tools", pid: 3))    // other app, same category
        sensor.handle(activation(nil, pid: 4))
        let samples = await collect(sensor, stream)
        #expect(samples.map(\.value) == [2, 3, 2, 0])
        #expect(samples.allSatisfy { $0.sensor == .appswitch && $0.kind == .appActivated })
        #expect(samples.allSatisfy { $0.time == Date(timeIntervalSince1970: 100) })
    }

    @Test func yieldsFrontmostOnStartAndItIsNotASwitch() async throws {
        let source = FakeAppSource()
        source.front.withLock { $0 = activation("public.app-category.productivity", pid: 1) }
        let sensor = makeAppSwitchSensor(source: source)
        let stream = try sensor.start()
        sensor.handle(activation("public.app-category.productivity", pid: 1))   // same app: no sample
        let samples = await collect(sensor, stream)
        #expect(samples.map(\.kind) == [.appFrontmost])
        #expect(samples.map(\.value) == [1])
    }

    @Test func tellsFrontmostAtStartYieldsNothing() async throws {
        let source = FakeAppSource()
        source.front.withLock { $0 = activation("public.app-category.productivity", pid: 9, isTells: true) }
        let sensor = makeAppSwitchSensor(source: source)
        let stream = try sensor.start()
        let samples = await collect(sensor, stream)
        #expect(samples.isEmpty)
    }

    @Test func dropsActivationsOfTellsAndKeepsThePreviousApp() async throws {
        let sensor = makeAppSwitchSensor()
        let stream = try sensor.start()
        sensor.handle(activation("public.app-category.news", pid: 1))
        sensor.handle(activation("public.app-category.productivity", pid: 9, isTells: true))
        sensor.handle(activation("public.app-category.news", pid: 1))   // back to the same app: no switch
        let samples = await collect(sensor, stream)
        #expect(samples.map(\.value) == [4])
    }

    @Test func stopFinishesTheStreamAndIsSafeTwice() async throws {
        let source = FakeAppSource()
        let sensor = makeAppSwitchSensor(source: source)
        let stream = try sensor.start()
        await sensor.stop()
        await sensor.stop()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
        #expect(source.stops.withLock { $0 } == 2)
        sensor.handle(activation("public.app-category.news", pid: 1))   // after stop: no crash, no sample
    }

    @Test func aSampleHoldsNoText() async throws {
        let sensor = makeAppSwitchSensor()
        let stream = try sensor.start()
        sensor.handle(activation("public.app-category.social-networking", pid: 2))
        let samples = await collect(sensor, stream)
        let sample = try #require(samples.first)
        let allowed: Set<String> = ["sensor", "time", "kind", "value"]
        let labels = Mirror(reflecting: sample).children.compactMap(\.label)
        #expect(Set(labels) == allowed)
        for child in Mirror(reflecting: sample).children {
            #expect(!(child.value is String), "\(child.label ?? "")")
        }
    }

    @Test func newSourcesStoreNoBundleIDNameOrTitle() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = ["MacSensors/AppSwitchSensor.swift", "MacSensors/AppActivationSource.swift",
                     "../../TellsCore/Sources/TellsCore/AppSwitchExtractor.swift",
                     "../../TellsCore/Sources/TellsCore/AppCategoryMap.swift"]
        let banned = ["bundleIdentifier", "localizedName", "windowTitle", "kCGWindowName", "CFBundleName",
                      "CFBundleIdentifier", "executableURL", "NSLog", "print(", "Logger", "os_log"]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for word in banned { #expect(!code.contains(word), "\(file) has \(word)") }
        }
    }
}
