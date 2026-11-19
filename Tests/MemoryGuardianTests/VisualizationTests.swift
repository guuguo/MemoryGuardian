import Foundation
import Testing
@testable import MemoryGuardian

struct VisualizationTests {
    @Test func fanMotionStopsForMissingStoppedAndDisabledStates() {
        #expect(FanMotion.period(rpm: nil, enabled: true) == nil)
        #expect(FanMotion.period(rpm: 0, enabled: true) == nil)
        #expect(FanMotion.period(rpm: -1, enabled: true) == nil)
        #expect(FanMotion.period(rpm: .nan, enabled: true) == nil)
        #expect(FanMotion.period(rpm: 4000, enabled: false) == nil)
        #expect(FanMotion.period(rpm: 2000, enabled: true)! > FanMotion.period(rpm: 5000, enabled: true)!)
        #expect(FanMotion.period(rpm: 7000, enabled: true) == FanMotion.period(rpm: 9000, enabled: true))
    }

    @Test func hoverUsesActualSamplesWithoutFillingMissingValuesOrLongGaps() {
        let start = Date(timeIntervalSince1970: 100)
        let history = [LoadHistoryPoint(timestamp: start, cpuPercent: 20, appCPU: ["a": 0.2]),
                       LoadHistoryPoint(timestamp: start.addingTimeInterval(5), cpuPercent: nil, appCPU: [:]),
                       LoadHistoryPoint(timestamp: start.addingTimeInterval(40), cpuPercent: 40, appCPU: ["a": 0.7])]
        let first = PlotSamples.nearest(in: history, fraction: 0)!
        #expect(first.timestamp == start)
        let missing = PlotSamples.nearest(in: history, fraction: 0.125)!
        #expect(PlotSamples.value(missing, appKey: nil) == nil)
        #expect(PlotSamples.value(missing, appKey: "a") == nil)
        #expect(PlotSamples.nearest(in: history, fraction: 0.5) == nil)
        #expect(PlotSamples.nearest(in: [], fraction: 0.5) == nil)
        #expect(PlotSamples.ceiling(history: history, appKey: nil) == 100)
        #expect(PlotSamples.ceiling(history: history, appKey: "a") == 1)
        #expect(PlotSamples.ceiling(history: history, appKey: "unknown") == 1)
    }
}
