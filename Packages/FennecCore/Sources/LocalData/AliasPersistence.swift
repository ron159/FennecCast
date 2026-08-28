import Foundation
import GRDB

public enum AliasEntityKind: String, Equatable, Sendable {
  case feed
  case episode
}

extension LocalDataStore {
  public func recordAlias(
    from aliasKey: String,
    to canonicalKey: String,
    kind: AliasEntityKind,
    updatedAtMilliseconds: Int64
  ) async throws {
    try await writer.write { db in
      try Self.recordAlias(
        from: aliasKey,
        to: canonicalKey,
        kind: kind,
        updatedAtMilliseconds: updatedAtMilliseconds,
        db: db
      )
    }
  }

  static func recordAlias(
    from aliasKey: String,
    to canonicalKey: String,
    kind: AliasEntityKind,
    updatedAtMilliseconds: Int64,
    db: Database
  ) throws {
    try validateAliasKey(aliasKey)
    try validateAliasKey(canonicalKey)
    guard updatedAtMilliseconds >= 0 else {
      throw LocalDataError.negativeTimestamp
    }
    guard aliasKey != canonicalKey else {
      throw LocalDataError.aliasCycle
    }
    if let existing = try fetchAlias(aliasKey, db: db) {
      guard existing.kind == kind else {
        throw LocalDataError.aliasKindMismatch
      }
      guard existing.canonicalKey == canonicalKey else {
        throw LocalDataError.aliasConflict(
          existing: existing.canonicalKey,
          requested: canonicalKey
        )
      }
      return
    }

    _ = try resolveCanonicalKey(
      canonicalKey,
      kind: kind,
      rejecting: aliasKey,
      db: db
    )
    try db.execute(
      sql: """
        INSERT INTO sync_aliases(alias_key, canonical_key, entity_kind, updated_at_ms)
        VALUES (?, ?, ?, ?)
        """,
      arguments: [aliasKey, canonicalKey, kind.rawValue, updatedAtMilliseconds]
    )
  }

  public func resolveCanonicalKey(
    _ key: String,
    kind: AliasEntityKind
  ) async throws -> String {
    try Self.validateAliasKey(key)
    return try await writer.read { db in
      try Self.resolveCanonicalKey(key, kind: kind, rejecting: nil, db: db)
    }
  }

  private static func validateAliasKey(_ key: String) throws {
    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LocalDataError.emptyAliasKey
    }
  }

  private static func resolveCanonicalKey(
    _ key: String,
    kind: AliasEntityKind,
    rejecting rejectedKey: String?,
    db: Database
  ) throws -> String {
    var current = key
    var visited = Set<String>()

    while true {
      if current == rejectedKey {
        throw LocalDataError.aliasCycle
      }
      guard visited.insert(current).inserted else {
        throw LocalDataError.aliasCycle
      }
      guard let alias = try fetchAlias(current, db: db) else {
        return current
      }
      guard alias.kind == kind else {
        throw LocalDataError.aliasKindMismatch
      }
      current = alias.canonicalKey
    }
  }

  private static func fetchAlias(
    _ key: String,
    db: Database
  ) throws -> (canonicalKey: String, kind: AliasEntityKind)? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT canonical_key, entity_kind
          FROM sync_aliases
          WHERE alias_key = ?
          """,
        arguments: [key]
      )
    else {
      return nil
    }
    let kindValue: String = row["entity_kind"]
    guard let kind = AliasEntityKind(rawValue: kindValue) else {
      throw LocalDataError.corruptRecord("invalid alias entity kind")
    }
    return (canonicalKey: row["canonical_key"], kind: kind)
  }
}
