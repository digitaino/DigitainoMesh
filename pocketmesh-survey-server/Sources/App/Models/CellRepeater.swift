import Fluent
import Vapor

/// Repeaters observed in each cell (many-to-many), with optional per-repeater signal metrics.
final class CellRepeater: Model, Content, @unchecked Sendable {
    static let schema = "cell_repeaters"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    @Parent(key: "cell_id")
    var cell: CellModel

    @Field(key: "repeater_hex_id")
    var repeaterHexID: String

    // Per-repeater signal metrics (nil for legacy data before v1.2 uploads)
    @OptionalField(key: "average_snr")
    var averageSNR: Double?

    @OptionalField(key: "average_rssi")
    var averageRSSI: Double?

    @OptionalField(key: "packet_count")
    var packetCount: Int?

    init() {}

    init(cellID: Int, repeaterHexID: String, averageSNR: Double? = nil, averageRSSI: Double? = nil, packetCount: Int? = nil) {
        self.$cell.id = cellID
        self.repeaterHexID = repeaterHexID
        self.averageSNR = averageSNR
        self.averageRSSI = averageRSSI
        self.packetCount = packetCount
    }
}
