import Foundation
import MeshCore

// MARK: - Device Channel Slot

/// A snapshot of one channel slot read from the device during the import read phase.
/// Consumed by ``planConfigImport``
/// so slot planning stays a pure, testable function.
struct DeviceChannelSlot: Equatable {
  let index: UInt8
  let name: String
  let secret: Data
  let isConfigured: Bool
}

// MARK: - Config Import Plan

/// A fully-resolved, validated set of writes produced from a `MeshCoreNodeConfig`
/// *before* any destructive device/database write begins.
///
/// Building a plan throws `NodeConfigServiceError` on any structural problem, so a
/// malformed or poison config is rejected up front and nothing is half-applied. The
/// execute phase then performs only writes that have already been proven applyable.
struct ConfigImportPlan: Equatable {
  struct Coordinate: Equatable {
    let latitude: Double
    let longitude: Double
  }

  struct ChannelWrite: Equatable {
    let index: UInt8
    let name: String
    let secret: Data
  }

  /// Validated 64-byte private key to push, when identity is selected and present.
  var importPrivateKey: Data?
  /// Node name to set, when identity is selected and present.
  var nodeName: String?
  /// Validated, in-range position to set.
  var position: Coordinate?
  /// Other-settings to merge at execute time (passed through verbatim, raw bytes preserved).
  var otherSettings: MeshCoreNodeConfig.OtherSettings?
  /// Validated radio parameters to write, when the radio section is selected and present.
  var radioSettings: MeshCoreNodeConfig.RadioSettings?
  /// Resolved channel writes (deduplicated; intra-import duplicates folded onto one slot).
  var channelWrites: [ChannelWrite]
  /// True when any channel write replaces an already-configured slot whose name/secret differs
  /// — i.e. the channels section is not purely additive for this config.
  var channelsOverwriteExisting: Bool
  /// Validated, deduplicated contact records ready to write (raw type byte preserved).
  var contactRecords: [MeshContact]
  /// Names of contacts whose coordinates in the file could not be used and were imported
  /// with no location instead. A contact's position came off the mesh, not from the user's
  /// hand — a repeater advertising junk must not block a whole radio migration.
  var contactCoordinateFallbacks: [String] = []
  /// Names of contacts left out because the device has no free slot for them. A migration is
  /// not refused wholesale over a handful of entries the radio cannot take: what fits is
  /// written, newest first, and the rest is reported.
  var contactCapacityDropped: [String] = []
}

// MARK: - Planner

/// Validates a `MeshCoreNodeConfig` against the device's capabilities and current channel
/// state, returning a ready-to-execute ``ConfigImportPlan`` or throwing the first problem.
///
/// Pure and synchronous so it is unit-testable without a live `MeshCoreSession` — mirrors the
/// `resolveEffectiveRadioID` seam pattern. Only sections present in `sections` are planned.
func planConfigImport(
  config: MeshCoreNodeConfig,
  sections: ConfigSections,
  maxChannels: UInt8,
  maxContacts: Int,
  maxTxPower: Int8,
  existingChannels: [DeviceChannelSlot],
  existingContacts: [String: MeshContact],
  protectedContactKeys: Set<String> = []
) throws -> ConfigImportPlan {
  var plan = ConfigImportPlan(
    importPrivateKey: nil,
    nodeName: nil,
    position: nil,
    otherSettings: nil,
    radioSettings: nil,
    channelWrites: [],
    channelsOverwriteExisting: false,
    contactRecords: []
  )

  if sections.nodeIdentity {
    plan.importPrivateKey = try planPrivateKey(config: config)
    plan.nodeName = config.name
  }

  if sections.positionSettings, let position = config.positionSettings {
    let lat = try validatedCoordinate(position.latitude, field: .positionLatitude, range: PacketBuilder.latitudeRange)
    let lon = try validatedCoordinate(position.longitude, field: .positionLongitude, range: PacketBuilder.longitudeRange)
    plan.position = ConfigImportPlan.Coordinate(latitude: lat, longitude: lon)
  }

  if sections.otherSettings {
    plan.otherSettings = config.otherSettings
  }

  if sections.radioSettings, let radio = config.radioSettings {
    plan.radioSettings = try planRadioSettings(radio, maxTxPower: maxTxPower)
  }

  if sections.channels, let channels = config.channels {
    let (writes, overwrite) = try planChannelWrites(
      channels, maxChannels: maxChannels, existingChannels: existingChannels
    )
    plan.channelWrites = writes
    plan.channelsOverwriteExisting = overwrite
  }

  if sections.contacts, let contacts = config.contacts {
    let planned = try planContactRecords(
      contacts, maxContacts: maxContacts, existingContacts: existingContacts,
      protectedKeys: protectedContactKeys
    )
    plan.contactRecords = planned.records
    plan.contactCoordinateFallbacks = planned.coordinateFallbacks
    plan.contactCapacityDropped = planned.capacityDropped
  }

  return plan
}

// MARK: - Identity

private func planPrivateKey(config: MeshCoreNodeConfig) throws -> Data? {
  guard let privateKeyHex = config.privateKey else { return nil }

  // A present-but-unparseable key must be rejected, not silently skipped. The key is the 64-byte
  // expanded Ed25519 secret (`clamp(SHA512(seed))`). The public key is derivable from this scalar
  // (firmware re-derives and validates it on import), but MC1's CryptoKit API operates on the
  // 32-byte seed, which the export omits, so MC1 cannot cheaply re-derive and cross-check it here
  // and takes the pairing on trust. Firmware additionally rejects all-00/FF-prefix keys and the
  // known test keypair; that content check is intentionally deferred to the device and is the one
  // identity failure that can surface at execute time, but firmware checks it before saving the
  // identity, so it still cannot leave a half-rotated identity.
  guard privateKeyHex.allSatisfy(\.isHexDigit),
        let privateKeyData = Data(hexString: privateKeyHex),
        privateKeyData.count == ProtocolLimits.privateKeySize else {
    throw NodeConfigServiceError.invalidPrivateKey(hexLength: privateKeyHex.count)
  }

  return privateKeyData
}

// MARK: - Coordinates

private func validatedCoordinate(_ raw: String, field: CoordinateField, range: ClosedRange<Double>) throws -> Double {
  guard let value = parseConfigCoordinate(raw, range: range) else {
    throw NodeConfigServiceError.invalidCoordinate(field: field, raw: raw)
  }
  return value
}

/// The firmware stores a coordinate as an `Int32` of microdegrees; some exporters write that
/// integer out unconverted.
private let microdegreesPerDegree = 1_000_000.0
/// The smallest integer read as microdegrees rather than as a mistyped degree value. Below this
/// the microdegree reading is a point within ~100 m of null island, which no mesh is at, while
/// a small out-of-range integer such as "91" is almost certainly a typo worth surfacing.
private let minimumMicrodegreeMagnitude = 1000.0

/// Reads a coordinate string from a config file, in decimal degrees.
///
/// The companion app writes plain decimal degrees, but a config can come from any exporter or a
/// hand edit, and a file rejected over a repeater's coordinate is a file nobody can import. So
/// this accepts the variants that mean one thing unambiguously: surrounding whitespace, a
/// decimal comma, an empty or `null` value for "no location" (the firmware's own 0/0), and a bare
/// integer of microdegrees — the value the firmware itself stores — when it only fits the range
/// once scaled. A non-finite or out-of-range value is still rejected rather than clamped, so a
/// mistyped number surfaces instead of silently landing at a pole.
func parseConfigCoordinate(_ raw: String, range: ClosedRange<Double>) -> Double? {
  var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  if text.isEmpty || ["null", "none", "nil"].contains(text.lowercased()) {
    return 0
  }
  // A single comma and no point is a locale decimal separator, not a list.
  if !text.contains("."), text.filter({ $0 == "," }).count == 1 {
    text = text.replacingOccurrences(of: ",", with: ".")
  }
  guard let value = Double(text), value.isFinite else { return nil }
  if range.contains(value) { return value }
  let isIntegerLiteral = !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "-" || $0 == "+") }
  if isIntegerLiteral, abs(value) >= minimumMicrodegreeMagnitude {
    let degrees = value / microdegreesPerDegree
    if range.contains(degrees) { return degrees }
  }
  return nil
}

// MARK: - Radio

/// Validates radio parameters against the firmware-accepted ranges so an out-of-range value from a
/// hand-edited backup is rejected up front rather than throwing at execute time, after the identity
/// has already been rotated. The txPower upper bound is the device-reported `maxTxPower`, since it is
/// hardware/build-specific; the other ranges are fixed firmware limits in `PacketBuilder`.
private func planRadioSettings(
  _ radio: MeshCoreNodeConfig.RadioSettings,
  maxTxPower: Int8
) throws -> MeshCoreNodeConfig.RadioSettings {
  guard PacketBuilder.frequencyRangeKHz.contains(radio.frequency) else {
    throw NodeConfigServiceError.invalidRadioSettings(field: .frequency)
  }
  guard PacketBuilder.bandwidthRangeHz.contains(radio.bandwidth) else {
    throw NodeConfigServiceError.invalidRadioSettings(field: .bandwidth)
  }
  guard PacketBuilder.spreadingFactorRange.contains(radio.spreadingFactor) else {
    throw NodeConfigServiceError.invalidRadioSettings(field: .spreadingFactor)
  }
  guard PacketBuilder.codingRateRange.contains(radio.codingRate) else {
    throw NodeConfigServiceError.invalidRadioSettings(field: .codingRate)
  }
  guard radio.txPower >= PacketBuilder.txPowerFloor, radio.txPower <= maxTxPower else {
    throw NodeConfigServiceError.invalidRadioSettings(field: .txPower)
  }
  return radio
}

// MARK: - Channels

/// Plans channel slot assignment with merge semantics, folding intra-import duplicates — same
/// hashtag name or secret — onto one slot so a config never consumes two slots for the same
/// channel, and flagging overwrites of already-configured slots.
private func planChannelWrites(
  _ channels: [MeshCoreNodeConfig.ChannelConfig],
  maxChannels: UInt8,
  existingChannels: [DeviceChannelSlot]
) throws -> (writes: [ConfigImportPlan.ChannelWrite], overwrite: Bool) {
  var hashtagNameToIndex: [String: UInt8] = [:]
  var secretToIndex: [String: UInt8] = [:]
  var emptyIndices: [UInt8] = []
  var existingByIndex: [UInt8: (name: String, secret: Data)] = [:]

  for slot in existingChannels where slot.index < maxChannels {
    if slot.isConfigured {
      existingByIndex[slot.index] = (slot.name, slot.secret)
      // Index every configured slot by secret, so a same-secret import folds onto it
      // regardless of whether the existing slot is a hashtag channel. Hashtag slots are
      // additionally indexed by their (already device-truncated) name.
      secretToIndex[slot.secret.hexString] = slot.index
      if slot.name.hasPrefix("#") {
        hashtagNameToIndex[slot.name.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)] = slot.index
      }
    } else {
      emptyIndices.append(slot.index)
    }
  }

  var writes: [ConfigImportPlan.ChannelWrite] = []
  var overwrite = false
  // The value each slot will hold given the writes planned so far, seeded from the device's
  // configured slots. The no-op skip compares against this, not the frozen `existingByIndex`, so
  // a later duplicate that restores a slot an earlier write changed is not dropped.
  var plannedByIndex = existingByIndex

  for (i, channel) in channels.enumerated() {
    guard channel.secret.allSatisfy(\.isHexDigit),
          let secretData = Data(hexString: channel.secret),
          secretData.count == ProtocolLimits.channelSecretSize else {
      throw NodeConfigServiceError.invalidChannelSecret(index: i, hexLength: channel.secret.count)
    }
    // Key on the re-hexed parsed bytes (canonical) so a config secret with non-canonical
    // casing still dedups against the device's canonically-keyed slots.
    let secretKey = secretData.hexString
    // The device stores names truncated to the firmware field width, so dedup and overwrite
    // comparison must use the truncated form — otherwise a long hashtag name misses its slot.
    let lookupName = channel.name.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)

    // The secret is firmware's channel-match key (findChannelIdx memcmp), so it must stay
    // single-homed. Resolve any slot the secret already occupies first; a hashtag-name match
    // must defer to it, otherwise a "#name"+new-secret import would duplicate that secret onto
    // the name's slot while its original slot still holds it, mis-attributing mesh traffic.
    let secretSlot = secretToIndex[secretKey]

    // A new channel goes back to the slot its file position names when that slot is free,
    // and only otherwise to the first free slot. The app keys channel history by slot number
    // and an export lists channels in slot order, so this puts a restored radio's channels
    // where its messages already are. It also means an intra-import duplicate folds onto its
    // first slot and simply leaves its own slot empty, instead of shifting every channel
    // after it down by one and filing their history under the wrong chats.
    let positionSlot = UInt8(clamping: i)
    let targetIndex: UInt8
    if let secretSlot {
      targetIndex = secretSlot
    } else if channel.name.hasPrefix("#"), let existing = hashtagNameToIndex[lookupName] {
      targetIndex = existing
    } else if let position = emptyIndices.firstIndex(of: positionSlot) {
      emptyIndices.remove(at: position)
      targetIndex = positionSlot
    } else if let empty = emptyIndices.first {
      emptyIndices.removeFirst()
      targetIndex = empty
    } else {
      throw NodeConfigServiceError.noAvailableChannelSlot(name: channel.name)
    }

    // Skip the write when the slot's effective value already matches, comparing the truncated
    // name the device actually stores. Writing it would re-commit /channels2 for no change.
    if let planned = plannedByIndex[targetIndex], planned.name == lookupName, planned.secret == secretData {
      // Keep the lookup tables current so a later same-key import still folds onto this slot.
      if channel.name.hasPrefix("#") { hashtagNameToIndex[lookupName] = targetIndex }
      secretToIndex[secretKey] = targetIndex
      continue
    }

    // An overwrite is a change to a slot the device itself had configured, so it keys off the
    // original device state rather than the in-progress planned state.
    if let original = existingByIndex[targetIndex], original.name != lookupName || original.secret != secretData {
      overwrite = true
    }

    // Update lookup tables so a later same-name/same-secret import folds onto this slot
    // instead of consuming a fresh one, and record the slot's new effective value.
    if channel.name.hasPrefix("#") {
      hashtagNameToIndex[lookupName] = targetIndex
    }
    secretToIndex[secretKey] = targetIndex
    plannedByIndex[targetIndex] = (lookupName, secretData)

    writes.append(ConfigImportPlan.ChannelWrite(index: targetIndex, name: channel.name, secret: secretData))
  }

  return (writes, overwrite)
}

// MARK: - Contacts

/// Validates and deduplicates the contacts array, returning ready-to-write records.
/// Dedups by public key (newest by `last_modified` wins), enforces device capacity, drops records
/// the device already stores byte-for-byte, and rejects invalid keys, path modes, coordinates, and
/// routing paths before any write.
/// `protectedKeys` are lowercase hex public keys of contacts the app holds history for —
/// favorites and anyone with a conversation — which an overflow must never leave out.
private func planContactRecords(
  _ contacts: [MeshCoreNodeConfig.ContactConfig],
  maxContacts: Int,
  existingContacts: [String: MeshContact],
  protectedKeys: Set<String> = []
) throws -> (records: [MeshContact], coordinateFallbacks: [String], capacityDropped: [String]) {
  var byKey: [String: (config: MeshCoreNodeConfig.ContactConfig, publicKey: Data)] = [:]
  var order: [String] = []

  for contact in contacts {
    guard contact.publicKey.allSatisfy(\.isHexDigit),
          let publicKey = Data(hexString: contact.publicKey),
          publicKey.count == ProtocolLimits.publicKeySize else {
      throw NodeConfigServiceError.invalidContactPublicKey(name: contact.name)
    }
    let key = publicKey.hexString
    if let existing = byKey[key] {
      if contact.lastModified >= existing.config.lastModified {
        byKey[key] = (contact, publicKey)
      }
    } else {
      byKey[key] = (contact, publicKey)
      order.append(key)
    }
  }

  // A firmware update of a key already on the device consumes no slot, so only keys not already
  // present count against free capacity. Checking remaining slots (not the absolute table size)
  // lets the non-destructive preview reject an overflow up front instead of failing partway
  // through the contact writes with `TABLE_FULL`, after identity and channels have committed.
  let newKeyCount = order.reduce(0) { count, key in
    existingContacts.keys.contains(key) ? count : count + 1
  }
  let availableSlots = max(0, maxContacts - existingContacts.count)
  var capacityDropped: [String] = []
  if newKeyCount > availableSlots {
    // Refusing the whole import over the overflow would block a radio migration (measured
    // 2026-09-01: 338 needed, 335 free), so leave out only as many as do not fit, and choose
    // them by disposability: never a contact the app holds history for, then the nodes the
    // mesh has heard from least recently (`last_advert`; a record's `last_modified` is a poor
    // proxy — a friend's entry that nothing rewrote in months sorts as "stale" by it, which is
    // exactly backwards). Ties break on the key so a re-run drops the same ones.
    let mostDisposableFirst = order
      .filter { !existingContacts.keys.contains($0) }
      .sorted { lhs, rhs in
        let l = byKey[lhs]!.config
        let r = byKey[rhs]!.config
        let lProtected = protectedKeys.contains(lhs)
        let rProtected = protectedKeys.contains(rhs)
        if lProtected != rProtected { return !lProtected }
        if l.lastAdvert != r.lastAdvert { return l.lastAdvert < r.lastAdvert }
        if l.lastModified != r.lastModified { return l.lastModified < r.lastModified }
        return lhs < rhs
      }
    let dropped = Set(mostDisposableFirst.prefix(newKeyCount - availableSlots))
    capacityDropped = order.filter { dropped.contains($0) }.map { byKey[$0]!.config.name }
    order.removeAll { dropped.contains($0) }
  }

  // Drop a record the device already stores byte-for-byte: re-adding it would arm a
  // /contacts3 rewrite for no change. A dropped record was an existing key, so it never
  // counted against free capacity above.
  var records: [MeshContact] = []
  var coordinateFallbacks: [String] = []
  for key in order {
    let entry = byKey[key]!
    let built = try buildContactRecord(entry.config, publicKey: entry.publicKey, hexKey: key)
    if built.coordinateFellBack {
      coordinateFallbacks.append(entry.config.name)
    }
    if let existing = existingContacts[key], persistedContactFieldsMatch(existing, built.record) {
      continue
    }
    records.append(built.record)
  }
  return (records, coordinateFallbacks, capacityDropped)
}

/// True when `existing` (a device-resident contact) already stores exactly what `record` would
/// write, so the contact-add would re-commit `/contacts3` for nothing. Compares only the fields the
/// add frame carries and the firmware persists; `lastAdvertisement` is excluded (volatile,
/// advert-driven). A genuine edit always bumps `lastModified`, so a changed contact is never
/// skipped. Names compare at the firmware field width, and coordinates by the integer the device
/// actually stores, so a difference the device cannot represent is treated as equal.
private func persistedContactFieldsMatch(_ existing: MeshContact, _ record: MeshContact) -> Bool {
  guard existing.typeRawValue == record.typeRawValue,
        existing.flags == record.flags,
        existing.outPathLength == record.outPathLength,
        existing.advertisedName.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
        == record.advertisedName.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes),
        existing.outPath.prefix(existing.pathByteLength) == record.outPath.prefix(record.pathByteLength),
        Int(existing.lastModified.timeIntervalSince1970) == Int(record.lastModified.timeIntervalSince1970) else {
    return false
  }
  return PacketBuilder.scaledCoordinate(existing.latitude, in: PacketBuilder.latitudeRange)
    == PacketBuilder.scaledCoordinate(record.latitude, in: PacketBuilder.latitudeRange)
    && PacketBuilder.scaledCoordinate(existing.longitude, in: PacketBuilder.longitudeRange)
    == PacketBuilder.scaledCoordinate(record.longitude, in: PacketBuilder.longitudeRange)
}

/// Builds one validated contact record. `publicKey` and `hexKey` are the already-decoded key
/// and its lowercase hex from ``planContactRecords``, so the key is parsed exactly once.
///
/// A coordinate that cannot be read or is out of range does not reject the record. The node's
/// own position is strict because the user typed it; a contact's position came off the mesh
/// in an advert, and a repeater advertising junk — the firmware stores any `Int32`, well past
/// ±90° — must not block a whole radio migration. Such a contact is written with no location
/// (the firmware's own 0/0) and reported back so the user knows which ones.
private func buildContactRecord(
  _ contact: MeshCoreNodeConfig.ContactConfig,
  publicKey: Data,
  hexKey: String
) throws -> (record: MeshContact, coordinateFellBack: Bool) {
  let (outPath, outPathLength) = try resolveOutPath(contact)

  let parsedLat = parseConfigCoordinate(contact.latitude, range: PacketBuilder.latitudeRange)
  let parsedLon = parseConfigCoordinate(contact.longitude, range: PacketBuilder.longitudeRange)
  let coordinateFellBack = parsedLat == nil || parsedLon == nil
  let lat = coordinateFellBack ? 0 : parsedLat!
  let lon = coordinateFellBack ? 0 : parsedLon!

  let record = MeshContact(
    id: hexKey,
    publicKey: publicKey,
    type: ContactType(rawValue: contact.type) ?? .chat,
    typeRawValue: contact.type,
    flags: ContactFlags(rawValue: contact.flags),
    outPathLength: outPathLength,
    outPath: outPath,
    advertisedName: contact.name,
    lastAdvertisement: Date(timeIntervalSince1970: TimeInterval(contact.lastAdvert)),
    latitude: lat,
    longitude: lon,
    lastModified: Date(timeIntervalSince1970: TimeInterval(contact.lastModified))
  )
  return (record, coordinateFellBack)
}

/// Resolves the encoded out-path for a contact, rejecting malformed routing data instead of
/// silently downgrading a routed contact to direct.
private func resolveOutPath(_ contact: MeshCoreNodeConfig.ContactConfig) throws -> (path: Data, length: UInt8) {
  guard let pathHex = contact.outPath else {
    // Absent path: flood routing.
    return (Data(), PacketBuilder.floodPathSentinel)
  }
  if pathHex.isEmpty {
    // Explicit empty string: direct contact.
    return (Data(), 0)
  }
  // `Data(hexString:)` silently drops non-hex characters, so a routed path like "zzz" would
  // parse to empty and masquerade as direct. Require contiguous, even-length hex up front.
  guard pathHex.count.isMultiple(of: 2),
        pathHex.allSatisfy(\.isHexDigit),
        let pathData = Data(hexString: pathHex), !pathData.isEmpty else {
    throw NodeConfigServiceError.invalidOutPath(name: contact.name)
  }
  let mode = contact.pathHashMode ?? 0
  guard mode <= UInt8(PathEncoding.maxPathHashMode) else {
    throw NodeConfigServiceError.invalidPathHashMode(name: contact.name, mode: mode)
  }
  let hashSize = Int(mode) + 1
  // Reject paths that would silently truncate (non-multiple length, hop count past the 6-bit
  // field) or exceed the firmware out-path buffer (firmware `isValidPathLen`).
  guard pathData.count % hashSize == 0,
        pathData.count / hashSize <= PathEncoding.maxHopCount,
        pathData.count <= PathEncoding.maxPathBytes else {
    throw NodeConfigServiceError.invalidOutPath(name: contact.name)
  }
  let hopCount = pathData.count / hashSize
  return (pathData, encodePathLen(hashSize: hashSize, hopCount: hopCount))
}
