// amdgpu_mtopg — helpers shared by the models and views, without AppKit.
//
// Upstream these live in MonitorModel.swift (SampleHistory's window and
// point cap, fmt/fmtInt), which LinuxModel.swift depends on.
//
// MIT License — see THIRD_PARTY.md (amdgpu_mtopg).

import Foundation

enum SampleHistory {
    static let windowNs: UInt64 = 60_000_000_000   // 60 s
    static let maxPoints = 1200                   // 10 Hz * 120 s safety
}

func fmt(_ value: Double?, _ places: Int = 1) -> String {
    guard let v = value, v.isFinite else { return "n/a" }
    return String(format: "%.\(places)f", v)
}

func fmtInt(_ value: Double?) -> String {
    guard let v = value, v.isFinite else { return "n/a" }
    return String(format: "%.0f", v)
}

func errnoText(_ e: Int32) -> String { "\(String(cString: strerror(e))) (errno \(e))" }
