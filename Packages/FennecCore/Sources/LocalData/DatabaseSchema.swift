import GRDB

enum DatabaseSchema {
  // GRDB migrations are ordered and each migration is transaction-wrapped.
  // Source: https://github.com/groue/GRDB.swift/blob/master/GRDB/Migration/DatabaseMigrator.swift
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1.initial") { db in
      try createFeeds(db)
      try createFeedSettings(db)
      try createEpisodes(db)
      try createEpisodeState(db)
      try createQueueEntries(db)
      try createMediaLocal(db)
      try createSyncOutbox(db)
      try createSyncCursor(db)
      try createSyncAliases(db)
    }
    migrator.registerMigration("v2.libraryIndexes") { db in
      try db.execute(
        sql: "CREATE INDEX feeds_subscription_title ON feeds(subscribed, title COLLATE NOCASE)"
      )
      try db.execute(sql: "CREATE INDEX episodes_publication_date ON episodes(publication_date_ms)")
      try db.execute(sql: "CREATE INDEX episode_state_inbox ON episode_state(inbox, episode_key)")
      try db.execute(
        sql: "CREATE INDEX episode_state_favorite ON episode_state(favorite, episode_key)"
      )
      try db.execute(sql: "CREATE INDEX episode_state_played ON episode_state(played, episode_key)")
      try db.execute(
        sql: "CREATE INDEX episode_state_archived ON episode_state(archived, episode_key)"
      )
    }
    migrator.registerMigration("v3.downloadRecovery") { db in
      try db.execute(sql: "ALTER TABLE media_local ADD COLUMN resume_data BLOB")
      try db.execute(
        sql: """
          ALTER TABLE media_local ADD COLUMN downloaded_bytes INTEGER NOT NULL DEFAULT 0
            CHECK (downloaded_bytes >= 0)
          """
      )
      try db.execute(
        sql: """
          CREATE INDEX media_local_state
          ON media_local(download_state, updated_at_ms DESC, episode_key)
          """
      )
    }
    migrator.registerMigration("v4.syncClock") { db in
      try db.execute(
        sql: """
          ALTER TABLE sync_cursor ADD COLUMN hlc_wall_ms INTEGER NOT NULL DEFAULT 0
            CHECK (hlc_wall_ms >= 0)
          """
      )
      try db.execute(
        sql: """
          ALTER TABLE sync_cursor ADD COLUMN hlc_counter INTEGER NOT NULL DEFAULT 0
            CHECK (hlc_counter >= 0)
          """
      )
    }
    migrator.registerMigration("v5.episodeSupplementalContent") { db in
      try db.execute(sql: "ALTER TABLE episodes ADD COLUMN transcript_url TEXT")
      try db.execute(sql: "ALTER TABLE episodes ADD COLUMN transcript_type TEXT")
      try db.execute(sql: "ALTER TABLE episodes ADD COLUMN chapters_url TEXT")
      try db.execute(sql: "ALTER TABLE episodes ADD COLUMN chapters_type TEXT")
    }
    return migrator
  }

  private static func createFeeds(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE feeds (
          feed_key TEXT PRIMARY KEY NOT NULL,
          canonical_url TEXT NOT NULL UNIQUE,
          title TEXT NOT NULL DEFAULT '',
          author TEXT,
          description_html TEXT,
          image_url TEXT,
          subscribed INTEGER NOT NULL DEFAULT 1 CHECK (subscribed IN (0, 1)),
          archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
          etag TEXT,
          last_modified TEXT,
          last_refresh_at_ms INTEGER,
          created_at_ms INTEGER NOT NULL DEFAULT 0 CHECK (created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL DEFAULT 0 CHECK (updated_at_ms >= 0),
          subscription_hlc_wall_ms INTEGER NOT NULL DEFAULT 0
            CHECK (subscription_hlc_wall_ms >= 0),
          subscription_hlc_counter INTEGER NOT NULL DEFAULT 0
            CHECK (subscription_hlc_counter >= 0),
          subscription_device_id TEXT NOT NULL DEFAULT ''
        )
        """
    )
  }

  private static func createFeedSettings(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE feed_settings (
          feed_key TEXT PRIMARY KEY NOT NULL
            REFERENCES feeds(feed_key) ON DELETE CASCADE,
          auto_download INTEGER NOT NULL DEFAULT 0 CHECK (auto_download IN (0, 1)),
          playback_speed REAL,
          skip_intro_ms INTEGER NOT NULL DEFAULT 0 CHECK (skip_intro_ms >= 0),
          skip_ending_ms INTEGER NOT NULL DEFAULT 0 CHECK (skip_ending_ms >= 0),
          tags_json BLOB
        )
        """
    )
  }

  private static func createEpisodes(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE episodes (
          episode_key TEXT PRIMARY KEY NOT NULL,
          feed_key TEXT NOT NULL REFERENCES feeds(feed_key) ON DELETE CASCADE,
          guid TEXT,
          enclosure_url TEXT,
          link_url TEXT,
          title TEXT NOT NULL DEFAULT '',
          publication_date_ms INTEGER,
          duration_ms INTEGER CHECK (duration_ms IS NULL OR duration_ms >= 0),
          description_html TEXT,
          mime_type TEXT,
          discovered_at_ms INTEGER NOT NULL DEFAULT 0 CHECK (discovered_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL DEFAULT 0 CHECK (updated_at_ms >= 0)
        )
        """
    )
    try db.execute(
      sql: "CREATE INDEX episodes_feed_date ON episodes(feed_key, publication_date_ms)")
  }

  private static func createEpisodeState(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE episode_state (
          episode_key TEXT PRIMARY KEY NOT NULL,
          inbox INTEGER NOT NULL DEFAULT 0 CHECK (inbox IN (0, 1)),
          favorite INTEGER NOT NULL DEFAULT 0 CHECK (favorite IN (0, 1)),
          archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
          played INTEGER NOT NULL DEFAULT 0 CHECK (played IN (0, 1)),
          position_ms INTEGER NOT NULL DEFAULT 0 CHECK (position_ms >= 0),
          duration_ms INTEGER CHECK (duration_ms IS NULL OR duration_ms >= 0),
          played_duration_ms INTEGER NOT NULL DEFAULT 0 CHECK (played_duration_ms >= 0),
          playback_intent TEXT NOT NULL DEFAULT 'checkpoint'
            CHECK (playback_intent IN (
              'checkpoint', 'playback_pause', 'seek', 'mark_played', 'mark_unplayed'
            )),
          feed_url TEXT,
          guid TEXT,
          playback_hlc_wall_ms INTEGER NOT NULL DEFAULT 0
            CHECK (playback_hlc_wall_ms >= 0),
          playback_hlc_counter INTEGER NOT NULL DEFAULT 0
            CHECK (playback_hlc_counter >= 0),
          playback_device_id TEXT NOT NULL DEFAULT ''
        )
        """
    )
  }

  private static func createQueueEntries(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE queue_entries (
          episode_key TEXT PRIMARY KEY NOT NULL,
          order_token TEXT NOT NULL,
          added_at_ms INTEGER NOT NULL DEFAULT 0 CHECK (added_at_ms >= 0),
          present INTEGER NOT NULL DEFAULT 1 CHECK (present IN (0, 1)),
          queue_hlc_wall_ms INTEGER NOT NULL DEFAULT 0 CHECK (queue_hlc_wall_ms >= 0),
          queue_hlc_counter INTEGER NOT NULL DEFAULT 0 CHECK (queue_hlc_counter >= 0),
          queue_device_id TEXT NOT NULL DEFAULT ''
        )
        """
    )
    try db.execute(sql: "CREATE INDEX queue_present_order ON queue_entries(present, order_token)")
  }

  private static func createMediaLocal(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE media_local (
          episode_key TEXT PRIMARY KEY NOT NULL
            REFERENCES episodes(episode_key) ON DELETE CASCADE,
          download_state TEXT NOT NULL DEFAULT 'not_requested',
          task_identifier INTEGER,
          local_relative_path TEXT,
          etag TEXT,
          last_modified TEXT,
          content_length INTEGER CHECK (content_length IS NULL OR content_length >= 0),
          checksum_sha256 TEXT,
          last_error TEXT,
          updated_at_ms INTEGER NOT NULL DEFAULT 0 CHECK (updated_at_ms >= 0)
        )
        """
    )
  }

  private static func createSyncOutbox(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE sync_outbox (
          device_id TEXT NOT NULL,
          local_seq INTEGER NOT NULL CHECK (local_seq >= 0),
          hlc_wall_ms INTEGER NOT NULL CHECK (hlc_wall_ms >= 0),
          hlc_counter INTEGER NOT NULL CHECK (hlc_counter >= 0),
          entity_type TEXT NOT NULL
            CHECK (entity_type IN ('subscription', 'episode_playback', 'queue_entry')),
          entity_key TEXT NOT NULL,
          envelope_json BLOB NOT NULL,
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          PRIMARY KEY (device_id, local_seq)
        )
        """
    )
  }

  private static func createSyncCursor(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE sync_cursor (
          singleton_id INTEGER PRIMARY KEY NOT NULL DEFAULT 1 CHECK (singleton_id = 1),
          server_seq INTEGER NOT NULL DEFAULT 0 CHECK (server_seq >= 0),
          last_local_seq INTEGER NOT NULL DEFAULT 0 CHECK (last_local_seq >= 0),
          device_id TEXT NOT NULL DEFAULT ''
        )
        """
    )
    try db.execute(
      sql: """
        INSERT INTO sync_cursor(singleton_id, server_seq, last_local_seq, device_id)
        VALUES (1, 0, 0, '')
        """
    )
  }

  private static func createSyncAliases(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE sync_aliases (
          alias_key TEXT PRIMARY KEY NOT NULL,
          canonical_key TEXT NOT NULL,
          entity_kind TEXT NOT NULL CHECK (entity_kind IN ('feed', 'episode')),
          updated_at_ms INTEGER NOT NULL DEFAULT 0 CHECK (updated_at_ms >= 0),
          CHECK (alias_key <> canonical_key)
        )
        """
    )
  }
}
