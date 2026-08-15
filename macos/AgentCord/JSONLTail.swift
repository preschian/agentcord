//
//  JSONLTail.swift
//  AgentCord
//
//  Incremental reader for append-only JSONL transcripts. Session files grow
//  continuously while an agent is working; re-reading the whole file on every
//  mtime change is the expensive path. This cursor keeps the byte offset and
//  any incomplete trailing line so each refresh only parses new bytes.
//

import Foundation

struct JSONLCursor {
    var offset: Int64 = 0
    var leftover = Data()

    mutating func reset() {
        offset = 0
        leftover.removeAll(keepingCapacity: true)
    }

    /// Newly completed UTF-8 lines since the last pull. `didReset` is true when
    /// the file shrank (rotated / rewritten) and the caller must drop any
    /// aggregate built from earlier bytes.
    mutating func pullLines(from url: URL) -> (lines: [String], didReset: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], false)
        }
        defer { try? handle.close() }

        let size: Int64
        do {
            size = Int64(try handle.seekToEnd())
        } catch {
            return ([], false)
        }

        var didReset = false
        if size < offset {
            reset()
            didReset = true
        }

        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            return ([], didReset)
        }

        let chunk = (try? handle.readToEnd()) ?? Data()
        if chunk.isEmpty && leftover.isEmpty {
            return ([], didReset)
        }
        leftover.append(chunk)
        offset = size

        var lines: [String] = []
        let newline = Data([0x0A])
        while let range = leftover.range(of: newline) {
            let lineData = leftover.subdata(in: leftover.startIndex..<range.lowerBound)
            leftover.removeSubrange(leftover.startIndex..<range.upperBound)
            if lineData.isEmpty { continue }
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return (lines, didReset)
    }
}
