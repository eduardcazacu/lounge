#!/usr/bin/env swift
// Summarises the timings exported from Settings → Timings.
//
//   swift ios/tools/journey-report.swift journeys.jsonl [more.jsonl …]
//
// Each journey is split by the attributes that change what it measures — a
// cold notification tap and a warm one are different waits, and so are a photo
// and a clip — and every mark is summarised as well as the total, because
// the marks say which step to blame. Failures are counted but kept out of the
// percentiles: how long something took to fail is a different question.

import Foundation

struct Mark: Decodable { let name: String; let ms: Int }
struct Record: Decodable {
    let journey: String
    let totalMs: Int
    let outcome: String
    let attributes: [String: String]
    let marks: [Mark]
    let build: String
    let device: String
}

// Mirrors `JourneyLog.successes`.
let successes: Set<String> = ["ok", "shown", "playing", "composing", "recording", "accepted"]
// The attributes worth splitting on. The rest (sizes, link timings) vary per
// record and would give every record a group of its own.
let splitBy = ["source", "launch", "media", "inboxCached", "prewarmed"]

let paths = CommandLine.arguments.dropFirst()
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: swift journey-report.swift journeys.jsonl [more.jsonl …]\n".utf8))
    exit(64)
}

var records: [Record] = []
for path in paths {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        exit(66)
    }
    records += text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
}

func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
    sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
}

func stats(_ values: [Int]) -> String {
    let sorted = values.sorted()
    return String(
        format: "n=%-4d p50 %6d   p90 %6d   max %6d",
        sorted.count, percentile(sorted, 0.5), percentile(sorted, 0.9), sorted.last!
    )
}

let builds = Set(records.map(\.build)).sorted().joined(separator: ", ")
let devices = Set(records.map(\.device)).sorted().joined(separator: ", ")
print("\(records.count) records · builds: \(builds) · devices: \(devices)\n")

// A file exported without clearing holds more than one build, and comparing
// them is usually why it was exported.
let splitsByBuild = Set(records.map(\.build)).count > 1
let groups = Dictionary(grouping: records) { record in
    ([record.journey] + (splitsByBuild ? ["build=\(record.build)"] : [])
        + splitBy.compactMap { key in record.attributes[key].map { "\(key)=\($0)" } })
        .joined(separator: " ")
}

for name in groups.keys.sorted() {
    let group = groups[name]!
    let good = group.filter { successes.contains($0.outcome) }
    let outcomes = Dictionary(grouping: group, by: \.outcome)
        .map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: " ")
    print("■ \(name)   [\(outcomes)]")
    guard !good.isEmpty else { print(); continue }
    print("  total                  \(stats(good.map(\.totalMs)))  ms")

    // Marks in the order they usually happen: by their median time.
    var byMark: [String: [Int]] = [:]
    for record in good {
        for mark in record.marks { byMark[mark.name, default: []].append(mark.ms) }
    }
    for (mark, values) in byMark.sorted(by: { percentile($0.value.sorted(), 0.5) < percentile($1.value.sorted(), 0.5) }) {
        print("  \(mark.padding(toLength: 22, withPad: " ", startingAt: 0)) \(stats(values))  ms")
    }
    print()
}
