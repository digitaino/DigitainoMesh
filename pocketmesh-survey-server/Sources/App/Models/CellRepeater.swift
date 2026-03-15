import Fluent
import Vapor

/// Repeaters observed in each cell (many-to-many).
final class CellRepeater: Model, Content, @unchecked Sendable {
    static let schema = "cell_repeaters"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    @Parent(key: "cell_id")
    var cell: CellModel

    @Field(key: "repeater_hex_id")
    var repeaterHexID: String

    init() {}

    init(cellID: Int, repeaterHexID: String) {
        self.$cell.id = cellID
        self.repeaterHexID = repeaterHexID
    }
}
