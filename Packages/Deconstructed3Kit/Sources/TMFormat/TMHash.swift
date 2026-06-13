/// The 64-bit hash the `.tm_*` format uses to key type names and graph
/// connector (pin) names.
///
/// Observed: type entries in `__type_index.tm_meta` carry a `type_hash`, and
/// script-graph connections reference pins by `connector_hash`. Both are the
/// 64-bit MurmurHash64A of the UTF-8 name with seed `0` and the canonical
/// multiplier `m = 0xc6a4a7935bd1e995`. Known anchors (confirmed against real
/// captures): `murmur64a("tm_transform_component") == 0x8c878bd87b046f80`,
/// `murmur64a("translation") == 0x3e132861ebce0169`,
/// `murmur64a("component_type") == 0x772749b3cbf24a8f`.
///
/// This lets us turn a name into the hash a graph stores, and (via a known-name
/// table) recover a readable label for a stored hash.
public enum TMHash {
    /// MurmurHash64A of `string`'s UTF-8 bytes (seed `0`).
    public static func murmur64a(_ string: String) -> UInt64 {
        let m: UInt64 = 0xc6a4a7935bd1e995
        let r: UInt64 = 47
        let bytes = Array(string.utf8)
        let length = bytes.count

        var h: UInt64 = UInt64(length) &* m

        let blockCount = length / 8
        for block in 0..<blockCount {
            var k: UInt64 = 0
            for byte in 0..<8 {
                k |= UInt64(bytes[block * 8 + byte]) << (8 * byte)
            }
            k = k &* m
            k ^= k >> r
            k = k &* m
            h ^= k
            h = h &* m
        }

        let tail = blockCount * 8
        let remainder = length - tail
        if remainder > 0 {
            var k: UInt64 = 0
            for byte in 0..<remainder {
                k |= UInt64(bytes[tail + byte]) << (8 * byte)
            }
            h ^= k
            h = h &* m
        }

        h ^= h >> r
        h = h &* m
        h ^= h >> r
        return h
    }

    /// MurmurHash64A as the lowercase 16-digit hex string the format stores
    /// connector/type hashes as (e.g. `"3e132861ebce0169"`).
    public static func murmur64aHex(_ string: String) -> String {
        hex(murmur64a(string))
    }

    /// Lowercase, zero-padded 16-digit hex for a 64-bit hash.
    public static func hex(_ value: UInt64) -> String {
        let raw = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
    }
}
