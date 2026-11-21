import Foundation
#if os(macOS)
import Metal
#else
import os
#endif

/// What a GGUF model file says about itself, read from its header without loading the model.
struct GGUFInfo: Hashable, Sendable {
    var version: UInt32 = 0
    var architecture = ""
    var name: String?
    var sizeLabel: String?
    /// "model", or "mmproj" for a vision add-on that can't answer on its own.
    var type: String?
    var fileType: Int?
    var contextLength: Int?
    var layers: Int?
    var embedding: Int?
    var heads: Int?
    var kvHeads: Int?
    var keyLength: Int?
    var valueLength: Int?
    var vocabSize: Int?
    var splitCount: Int?
    var chatTemplate: String?
    var parameterCount: Int64 = 0

    /// "Llama 3.2 3B Instruct", from the file's own name for itself.
    /// Nil when the name is missing or a placeholder some converters write ("hf", "model").
    var displayName: String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), name.count >= 4,
              !["model", "models", "llama", "transformers"].contains(name.lowercased()) else { return nil }
        return name
    }

    /// "Q4_K_M", from the file type number llama.cpp writes.
    var quantization: String? {
        guard let fileType else { return nil }
        let names: [Int: String] = [
            0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1", 10: "Q2_K",
            11: "Q3_K_S", 12: "Q3_K_M", 13: "Q3_K_L", 14: "Q4_K_S", 15: "Q4_K_M", 16: "Q5_K_S", 17: "Q5_K_M",
            18: "Q6_K", 19: "IQ2_XXS", 20: "IQ2_XS", 21: "Q2_K_S", 22: "IQ3_XS", 23: "IQ3_XXS", 24: "IQ1_S",
            25: "IQ4_NL", 26: "IQ3_S", 27: "IQ3_M", 28: "IQ2_S", 29: "IQ2_M", 30: "IQ4_XS", 31: "IQ1_M",
            32: "BF16", 36: "TQ1_0", 37: "TQ2_0", 38: "MXFP4", 39: "NVFP4", 40: "Q1_0", 41: "Q2_0", 42: "F8_E4M3",
        ]
        return names[fileType]
    }

    /// "3.2B parameters"
    var parameterText: String? {
        guard parameterCount > 0 else { return sizeLabel.map { "\($0) parameters" } }
        let p = Double(parameterCount)
        return p >= 1e9 ? String(format: "%.1fB parameters", p / 1e9) : String(format: "%.0fM parameters", p / 1e6)
    }

    /// Bytes of attention memory (KV cache, 16-bit) each token of context takes. Errs high when unsure.
    var kvBytesPerToken: Int64 {
        guard let layers, layers > 0 else { return 256 << 10 }
        let heads = self.heads ?? 0
        let kvHeads = self.kvHeads ?? heads
        let headSize = (embedding ?? 4096) / max(heads, 1)
        let k = keyLength ?? headSize, v = valueLength ?? headSize
        // In floating point: the numbers come from the file, and a made-up file mustn't overflow and crash.
        let bytes = Double(layers) * Double(max(kvHeads, 1)) * (Double(k) + Double(v)) * 2
        return bytes.isFinite && bytes < 1e15 ? Int64(max(bytes, 0)) : Int64(1e15)
    }
}

enum GGUFError: LocalizedError {
    case unreadable, notGGUF, oldVersion(UInt32), damaged, visionAddOn, split(Int), contextTooSmall(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: "Offline Kit couldn't read this file. Check that it's still there and try again."
        case .notGGUF: "This isn't a GGUF model file. Choose a file that ends in .gguf, like the ones on Hugging Face marked GGUF."
        case .oldVersion(let v): "This model file uses an old GGUF format (version \(v)). Download a newer copy of the model."
        case .damaged: "This model file is incomplete or damaged. Download it again."
        case .visionAddOn: "This file is a vision add-on (a projector), not a model that can answer by itself. Choose the main model file."
        case .split(let n): "This model is split into \(n) files. Choose a single-file version instead; most models offer one, such as Q4_K_M."
        case .contextTooSmall(let n): "This model can only read \(n.formatted()) tokens at a time, which is too little for Ask's sources. Choose a newer model."
        }
    }
}

extension GGUFInfo {
    /// Reads the header and tensor list. Throws a plain-language `GGUFError` for anything that isn't a usable GGUF.
    static func read(_ url: URL) throws -> GGUFInfo {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { throw GGUFError.unreadable }
        return try data.withUnsafeBytes { raw in
            var r = Reader(bytes: raw)
            guard raw.count >= 24, r.u32() == 0x4655_4747 else { throw GGUFError.notGGUF }   // "GGUF"
            var info = GGUFInfo()
            info.version = r.u32()
            guard info.version >= 2 else { throw GGUFError.oldVersion(info.version) }
            guard info.version <= 3 else { throw GGUFError.notGGUF }
            let tensorCount = r.u64(), kvCount = r.u64()
            guard tensorCount < 1_000_000, kvCount < 1_000_000 else { throw GGUFError.damaged }

            var ints: [String: Int] = [:]
            var strings: [String: String] = [:]
            for _ in 0..<kvCount {
                let key = try r.string()
                let type = r.u32()
                if type == 9 {                                    // array
                    let elementType = r.u32(), count = r.u64()
                    guard count < 1 << 32 else { throw GGUFError.damaged }
                    if key == "tokenizer.ggml.tokens" { ints[key] = Int(count) }
                    if let size = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 10: 8, 11: 8][elementType] {
                        guard r.offset + Int(count) * size <= raw.count else { throw GGUFError.damaged }
                        // Per-layer values (like head counts on some models): keep the largest.
                        var largest = 0
                        for _ in 0..<count { largest = max(largest, try r.integer(elementType)) }
                        ints[key] = ints[key] ?? largest
                    } else {
                        for _ in 0..<count { try r.skip(elementType) }
                    }
                } else if type == 8 {
                    strings[key] = try r.string()
                } else if [0, 1, 2, 3, 4, 5, 7, 10, 11].contains(type) {
                    ints[key] = try r.integer(type)
                } else {
                    try r.skip(type)
                }
                guard !r.failed else { throw GGUFError.damaged }
            }

            let arch = strings["general.architecture"] ?? ""
            info.architecture = arch
            info.name = strings["general.name"]
            info.sizeLabel = strings["general.size_label"]
            info.type = strings["general.type"]
            info.fileType = ints["general.file_type"]
            info.splitCount = ints["split.count"]
            info.chatTemplate = strings["tokenizer.chat_template"]
            info.vocabSize = ints["tokenizer.ggml.tokens"]
            info.contextLength = ints["\(arch).context_length"]
            info.layers = ints["\(arch).block_count"]
            info.embedding = ints["\(arch).embedding_length"]
            info.heads = ints["\(arch).attention.head_count"]
            info.kvHeads = ints["\(arch).attention.head_count_kv"]
            info.keyLength = ints["\(arch).attention.key_length"]
            info.valueLength = ints["\(arch).attention.value_length"]

            // Tensor list: count the parameters and check the data they point to is really in the file.
            var lastOffset: UInt64 = 0
            for _ in 0..<tensorCount {
                _ = try r.string()
                let dims = r.u32()
                guard dims <= 8 else { throw GGUFError.damaged }
                var elements: Int64 = 1
                for _ in 0..<dims { elements = elements &* Int64(clamping: r.u64()) }
                _ = r.u32()                                       // tensor type
                lastOffset = max(lastOffset, r.u64())
                guard !r.failed else { throw GGUFError.damaged }
                info.parameterCount &+= elements
            }
            let alignment = UInt64(min(max(ints["general.alignment"] ?? 32, 1), 1 << 20))
            let dataStart = (UInt64(r.offset) + alignment - 1) / alignment * alignment
            let (end, overflow) = dataStart.addingReportingOverflow(lastOffset)
            guard tensorCount > 0, !overflow, end < UInt64(raw.count) else { throw GGUFError.damaged }
            return info
        }
    }

    /// The same, but nil for anything unreadable. Cached by path, size and date, since lists ask often.
    static func cached(_ url: URL) -> GGUFInfo? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let info = try? read(url)
        cache.withLock { $0[key] = .some(info) }
        return info
    }

    private static let cache = Locked<[String: GGUFInfo?]>([:])
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

/// Bounds-checked little-endian reads over the mapped file. Reading past the end sets `failed`.
private struct Reader {
    let bytes: UnsafeRawBufferPointer
    var offset = 0
    var failed = false

    init(bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    private mutating func take<T: FixedWidthInteger>(_: T.Type) -> T {
        let size = MemoryLayout<T>.size
        guard !failed, offset + size <= bytes.count else { failed = true; return 0 }
        defer { offset += size }
        return T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    mutating func u32() -> UInt32 { take(UInt32.self) }
    mutating func u64() -> UInt64 { take(UInt64.self) }

    mutating func string() throws -> String {
        let length = u64()
        guard !failed, length < 64 << 20, offset + Int(length) <= bytes.count else { throw GGUFError.damaged }
        defer { offset += Int(length) }
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + Int(length)]), as: UTF8.self)
    }

    mutating func integer(_ type: UInt32) throws -> Int {
        switch type {
        case 0, 7: return Int(take(UInt8.self))
        case 1: return Int(take(Int8.self))
        case 2: return Int(take(UInt16.self))
        case 3: return Int(take(Int16.self))
        case 4: return Int(take(UInt32.self))
        case 5: return Int(take(Int32.self))
        case 10: return Int(clamping: take(UInt64.self))
        case 11: return Int(take(Int64.self))
        default: throw GGUFError.damaged
        }
    }

    mutating func skip(_ type: UInt32) throws {
        let sizes: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
        if type == 8 { _ = try string(); return }
        if type == 9 {
            let elementType = u32(), count = u64()
            // Arrays of arrays aren't used by real models; refusing them keeps a made-up file from recursing forever.
            guard count < 1 << 32, elementType != 9 else { throw GGUFError.damaged }
            if let size = sizes[elementType] {
                let total = Int(count) * size
                guard offset + total <= bytes.count else { throw GGUFError.damaged }
                offset += total
            } else {
                for _ in 0..<count { try skip(elementType) }
            }
            return
        }
        guard let size = sizes[type], offset + size <= bytes.count else { throw GGUFError.damaged }
        offset += size
    }
}

/// Whether a model fits in this device's memory, and how much context to give it. Estimated before loading,
/// so an oversized model gets a plain message instead of failing (or freezing the device) mid-load.
enum ModelFit {
    /// Ask needs room for its instructions, sources and a full answer.
    static let minimumContext = 4096

    /// Context to aim for: more than this only feeds sources Ask already caps.
    static var preferredContext: Int {
        #if os(macOS)
        8192
        #else
        6144
        #endif
    }

    /// Bytes the model may use: Metal's working-set limit on a Mac, the app's own memory limit on iPhone and iPad.
    static let memoryBudget: Int64 = {
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        #if os(macOS)
        if let device = MTLCreateSystemDefaultDevice(), device.recommendedMaxWorkingSetSize > 0 {
            return Int64(device.recommendedMaxWorkingSetSize)
        }
        return physical * 2 / 3
        #elseif targetEnvironment(simulator)
        return physical / 2
        #else
        let available = Int64(os_proc_available_memory())
        return available > 0 ? available : physical / 2
        #endif
    }()

    /// Scratch space llama.cpp needs besides the weights and KV cache.
    static let overhead: Int64 = 600 << 20

    static func bytesNeeded(info: GGUFInfo, fileSize: Int64, context: Int) -> Int64 {
        fileSize + info.kvBytesPerToken * Int64(context) + overhead
    }

    enum Plan: Hashable, Sendable {
        case ready(contextTokens: Int32)
        case tooBig(needed: Int64, available: Int64)
        case contextTooSmall(Int)
    }

    /// The largest context (up to `preferredContext` and the model's own limit) that fits in memory.
    static func plan(info: GGUFInfo, fileSize: Int64, budget: Int64 = memoryBudget) -> Plan {
        let trained = info.contextLength ?? minimumContext
        guard trained >= minimumContext else { return .contextTooSmall(trained) }
        var context = min(trained, preferredContext) / 256 * 256
        while context > minimumContext, bytesNeeded(info: info, fileSize: fileSize, context: context) > budget {
            context = max(minimumContext, context - 1024)
        }
        let needed = bytesNeeded(info: info, fileSize: fileSize, context: context)
        guard needed <= budget else { return .tooBig(needed: needed, available: budget) }
        return .ready(contextTokens: Int32(context))
    }

    /// "this Mac", "this iPhone"
    static var deviceName: String {
        #if os(macOS)
        "this Mac"
        #else
        ProcessInfo.processInfo.isiOSAppOnMac ? "this Mac" : "this device"
        #endif
    }

    /// Decimal gigabytes, matching how file sizes are shown.
    static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
}
