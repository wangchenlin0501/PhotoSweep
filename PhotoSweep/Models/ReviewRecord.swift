import Foundation
import SwiftData

@Model
final class ReviewRecord {
    @Attribute(.unique) var assetIdentifier: String
    var reviewedAt: Date
    var eligibleAgainAt: Date

    init(assetIdentifier: String, reviewedAt: Date, eligibleAgainAt: Date) {
        self.assetIdentifier = assetIdentifier
        self.reviewedAt = reviewedAt
        self.eligibleAgainAt = eligibleAgainAt
    }
}
