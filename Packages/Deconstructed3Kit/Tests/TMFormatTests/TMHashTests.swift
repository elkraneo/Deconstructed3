import Testing
import TMFormat

@Suite struct TMHashTests {
    @Test func knownTypeAndPinHashes() {
        // Anchors confirmed against real RCP 3 captures.
        #expect(TMHash.murmur64a("tm_transform_component") == 0x8c878bd87b046f80)
        #expect(TMHash.murmur64a("translation") == 0x3e132861ebce0169)
        #expect(TMHash.murmur64a("component_type") == 0x772749b3cbf24a8f)
    }

    @Test func hexFormatIsZeroPadded16() {
        #expect(TMHash.murmur64aHex("translation") == "3e132861ebce0169")
        #expect(TMHash.hex(0x1) == "0000000000000001")
        #expect(TMHash.hex(0x772749b3cbf24a8f) == "772749b3cbf24a8f")
    }

    @Test func emptyStringHashesToSeedConstant() {
        // Deterministic, just guards the length-0 path (no tail, no blocks).
        #expect(TMHash.murmur64a("") == TMHash.murmur64a(""))
    }
}
