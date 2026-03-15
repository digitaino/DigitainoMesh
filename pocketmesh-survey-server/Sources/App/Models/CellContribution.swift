import Fluent
import Vapor

/// Tracks which contributor contributed to which cell.
/// Enables purging a contributor's data without losing other contributors' data.
final class CellContribution: Model, Content, @unchecked Sendable {
    static let schema = "cell_contributions"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    @Parent(key: "cell_id")
    var cell: CellModel

    @Field(key: "contributor_id")
    var contributorID: String

    @Field(key: "packet_count")
    var packetCount: Int

    @Field(key: "snr_weighted")
    var snrWeighted: Double

    @Field(key: "rssi_weighted")
    var rssiWeighted: Double?

    @Field(key: "flood_count")
    var floodCount: Int

    @Field(key: "direct_count")
    var directCount: Int

    @Field(key: "contributed_at")
    var contributedAt: String

    init() {}

    init(
        cellID: Int, contributorID: String,
        packetCount: Int, snrWeighted: Double, rssiWeighted: Double?,
        floodCount: Int, directCount: Int, contributedAt: String
    ) {
        self.$cell.id = cellID
        self.contributorID = contributorID
        self.packetCount = packetCount
        self.snrWeighted = snrWeighted
        self.rssiWeighted = rssiWeighted
        self.floodCount = floodCount
        self.directCount = directCount
        self.contributedAt = contributedAt
    }
}
