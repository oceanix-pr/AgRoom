// Adapted from Memonta (MIT); see application Notices/Memonta-MIT.txt.
import Foundation

public enum NoteSpeakerPrecision: Int, Codable, CaseIterable, Sendable {
    case fastest = 1, fast, standard, fine, finest
    var seconds: Double { switch self { case .fastest: 300; case .fast: 360; case .standard: 480; case .fine: 900; case .finest: 1200 } }
    var overlap: Double { switch self { case .fastest: 15; case .fast: 20; case .standard: 30; case .fine: 45; case .finest: 60 } }
    var shift: Float { switch self { case .fastest: 0.4; case .fast: 0.325; case .standard: 0.25; case .fine: 0.175; case .finest: 0.1 } }
}

public enum NoteSpeakerRefinement {
    private struct Cluster { var speakers: Set<Int>; var vector: [Float]; var duration: Double }
    public static func refine(_ result: NoteSpeakerResult) -> NoteSpeakerResult {
        var durations: [Int:Double] = [:]
        for turn in result.turns { durations[turn.speaker,default: 0] += max(0,turn.end - turn.start) }
        var clusters = durations.keys.sorted().map { Cluster(speakers: [$0],vector: result.embeddings[$0] ?? [],duration: durations[$0] ?? 0) }
        guard !clusters.isEmpty else { return result }
        func merge(_ i: Int,_ j: Int) {
            let a = clusters[i], b = clusters[j], weight = a.duration + b.duration
            if !a.vector.isEmpty, a.vector.count == b.vector.count, weight > 0 {
                clusters[i].vector = NoteVoiceprintMath.normalize(zip(a.vector,b.vector).map { ($0 * Float(a.duration) + $1 * Float(b.duration)) / Float(weight) })
            } else if a.vector.isEmpty { clusters[i].vector = b.vector }
            clusters[i].speakers.formUnion(b.speakers); clusters[i].duration = weight; clusters.remove(at: j)
        }
        let tiny = max(3,durations.values.reduce(0,+) * 0.05)
        for phase in 0..<2 {
            while clusters.count > 1 {
                var best: (Int,Int)?, score: Float = phase == 0 ? 0.6 : 0.5
                for i in clusters.indices where phase == 0 || clusters[i].duration < tiny {
                    for j in clusters.indices where j > i && (phase == 0 || clusters[j].duration < tiny) {
                        let candidate = NoteVoiceprintMath.cosine(clusters[i].vector,clusters[j].vector)
                        if candidate > score { score = candidate; best = (i,j) }
                    }
                }
                guard let best else { break }; merge(best.0,best.1)
            }
        }
        var assignment: [Int:Int] = [:]
        let big = clusters.indices.filter { clusters[$0].duration >= tiny }
        for index in clusters.indices {
            let target: Int
            if clusters[index].duration >= tiny { target = index }
            else if !big.isEmpty { target = big.max { NoteVoiceprintMath.cosine(clusters[$0].vector,clusters[index].vector) < NoteVoiceprintMath.cosine(clusters[$1].vector,clusters[index].vector) }! }
            else { target = clusters.indices.max { clusters[$0].duration < clusters[$1].duration }! }
            for speaker in clusters[index].speakers { assignment[speaker] = target }
        }
        var totals: [Int:Double] = [:]
        for turn in result.turns { totals[assignment[turn.speaker] ?? 0,default: 0] += turn.end - turn.start }
        let ordered = totals.keys.sorted { totals[$0] == totals[$1] ? $0 < $1 : totals[$0,default: 0] > totals[$1,default: 0] }
        let numbers = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1,$0) })
        let turns = result.turns.map { NoteSpeakerTurn(start: $0.start,end: $0.end,speaker: numbers[assignment[$0.speaker] ?? 0] ?? 0) }
        let vectors = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0,clusters[$1].vector) })
        return .init(turns: turns,embeddings: vectors,modelID: result.modelID)
    }
    public static func collapsed(_ records: [NoteVoiceprint]) -> [NoteVoiceprint] {
        Dictionary(grouping: records) { $0.name + ":" + $0.modelID + ":\($0.embedding.count)" }.values.map { group in
            var record = group.sorted { $0.id.uuidString < $1.id.uuidString }.first!
            let weights = group.map { min(100_000,max(1,$0.sampleCount ?? 1)) }, total = weights.reduce(0,+)
            record.embedding = NoteVoiceprintMath.normalize(record.embedding.indices.map { dimension in zip(group,weights).reduce(0) { $0 + $1.0.embedding[dimension] * Float($1.1) } / Float(total) })
            record.sampleCount = total; return record
        }.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
    }
    public static func identify(_ embeddings: [Int:[Float]], modelID: String, records: [NoteVoiceprint]) -> [Int:String] {
        let voices = collapsed(records.filter { $0.modelID == modelID })
        var candidates: [(Int,[(String,Float)])] = []
        for (speaker, vector) in embeddings.sorted(by: { $0.key < $1.key }) {
            var scored: [(String,Float)] = []
            for voice in voices { scored.append((voice.name,NoteVoiceprintMath.cosine(vector,voice.embedding))) }
            scored.sort { lhs, rhs in if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }; return lhs.1 > rhs.1 }
            guard let top = scored.first, top.1 >= 0.5, scored.count < 2 || top.1 - scored[1].1 >= 0.05 else { continue }
            candidates.append((speaker,Array(scored.filter { $0.1 >= 0.5 }.prefix(3))))
        }
        if candidates.count > 8 {
            var used = Set<String>(), mapping: [Int:String] = [:]
            let pairs = candidates.flatMap { speaker, options in options.map { (speaker,$0.0,$0.1) } }.sorted { $0.2 > $1.2 }
            for pair in pairs where mapping[pair.0] == nil && !used.contains(pair.1) { mapping[pair.0] = pair.1; used.insert(pair.1) }
            return mapping
        }
        var best: [Int:String] = [:], current: [Int:String] = [:], used = Set<String>(), score: Float = -1
        func search(_ index: Int,_ total: Float) {
            guard index < candidates.count else { if total > score { score = total; best = current }; return }
            search(index + 1,total)
            let (speaker,options) = candidates[index]
            for (name,value) in options where !used.contains(name) {
                used.insert(name); current[speaker] = name; search(index + 1,total + value); current[speaker] = nil; used.remove(name)
            }
        }
        search(0,0); return best
    }
}
