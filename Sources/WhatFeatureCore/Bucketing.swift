import Crypto

/// Puts each targeting key in a stable bucket for percentage rollouts.
///
/// The bucket must be the same on every server, every run, forever, or users would jump between
/// variants. That rules out Swift's `hashValue`, which is seeded randomly for each process.
public enum Bucketing {
    /// Buckets per flag. Rollout weights are out of this number, so 1 bucket is 0.01%.
    public static let bucketCount = 10_000

    /// A number from 0 to `bucketCount - 1`.
    ///
    /// The flag key is part of the hash so that each flag gets a different slice of users;
    /// otherwise the same 10% would be first in line for every rollout. Flag keys can't contain
    /// `/`, so the joined string is unambiguous.
    public static func bucket(flagKey: String, targetingKey: String) -> Int {
        let digest = SHA256.hash(data: Array("\(flagKey)/\(targetingKey)".utf8))
        let prefix = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        // The modulo bias is about 1 in 10^15, so it doesn't matter here.
        return Int(prefix % UInt64(bucketCount))
    }

    /// Picks the variant whose range contains `bucket`. Variants take ranges in order:
    /// `[on: 1000, off: 9000]` gives buckets 0–999 to `on` and 1000–9999 to `off`.
    ///
    /// Returns `nil` only for a rollout whose weights add up to less than the bucket number,
    /// which validation prevents.
    public static func variant(for bucket: Int, in rollout: [WeightedVariant]) -> String? {
        var upperBound = 0
        for entry in rollout {
            upperBound += entry.weight
            if bucket < upperBound { return entry.variant }
        }
        return nil
    }
}
