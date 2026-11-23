import Testing
@testable import MacSensors

/// D-034: the probe stays at 1 s, so the features of SPEC.md 3.2 do not change.
struct ActivityProbeRateTests {
    @Test func probeIntervalIsOneSecond() {
        #expect(SystemActivitySource.probeInterval == 1)
    }

    @Test func probeLeewayIsUnchanged() {
        #expect(SystemActivitySource.timerLeeway == .milliseconds(100))
    }
}
