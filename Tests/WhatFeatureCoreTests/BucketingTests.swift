import Testing
import WhatFeatureCore

@Suite struct BucketingTests {
    /// Reference values computed separately with Python's hashlib. If these change, every user
    /// would move to a different bucket, so treat a failure here as a breaking change.
    @Test(arguments: [
        ("new-onboarding", "user-123", 323),
        ("new-onboarding", "device-abc", 8975),
        ("checkout-v2", "user-123", 928),
    ])
    func matchesReferenceValues(_ flagKey: String, _ targetingKey: String, _ expected: Int) {
        #expect(Bucketing.bucket(flagKey: flagKey, targetingKey: targetingKey) == expected)
    }

    @Test func spreadsKeysEvenly() {
        let buckets = (0..<10_000).map { Bucketing.bucket(flagKey: "flag", targetingKey: "user-\($0)") }
        let inFirstTenth = buckets.count { $0 < 1_000 }
        // Expect about 1,000. A real deviation of more than ±150 here would be 5 standard deviations.
        #expect((850...1_150).contains(inFirstTenth))
        #expect(buckets.allSatisfy { (0..<Bucketing.bucketCount).contains($0) })
    }

    @Test func assignsVariantsByRange() {
        let rollout = [WeightedVariant(variant: "on", weight: 1_000), WeightedVariant(variant: "off", weight: 9_000)]
        #expect(Bucketing.variant(for: 0, in: rollout) == "on")
        #expect(Bucketing.variant(for: 999, in: rollout) == "on")
        #expect(Bucketing.variant(for: 1_000, in: rollout) == "off")
        #expect(Bucketing.variant(for: 9_999, in: rollout) == "off")
    }

    @Test func returnsNilWhenWeightsFallShort() {
        #expect(Bucketing.variant(for: 5_000, in: [WeightedVariant(variant: "on", weight: 1_000)]) == nil)
    }

    @Test func wideningARolloutKeepsExistingUsers() {
        func rollout(_ percentOn: Int) -> [WeightedVariant] {
            [WeightedVariant(variant: "on", weight: percentOn * 100), WeightedVariant(variant: "off", weight: (100 - percentOn) * 100)]
        }
        for index in 0..<2_000 {
            let bucket = Bucketing.bucket(flagKey: "flag", targetingKey: "user-\(index)")
            if Bucketing.variant(for: bucket, in: rollout(10)) == "on" {
                #expect(Bucketing.variant(for: bucket, in: rollout(20)) == "on")
            }
        }
    }

    @Test func differentFlagsGetDifferentSlices() {
        let users = (0..<1_000).map { "user-\($0)" }
        let inA = Set(users.filter { Bucketing.bucket(flagKey: "flag-a", targetingKey: $0) < 1_000 })
        let inB = Set(users.filter { Bucketing.bucket(flagKey: "flag-b", targetingKey: $0) < 1_000 })
        // With independent slices, about 1% of users are in both. Identical slices would be 10%.
        #expect(inA.intersection(inB).count < 50)
    }
}
