-- =====================================================================
-- john-k9 :: migration 0001 :: create k9_partnerships
--
-- WHO NEEDS THIS FILE: an existing installation whose `john-k9/sql/install.sql`
-- was applied BEFORE `k9_partnerships` existed in it (i.e. before
-- DEVELOPER_REFERENCE.md section 12.0 item 7's handler-partnership registry
-- landed). A fresh install never needs this file -- install.sql already
-- creates this table in final shape (including
-- `tenure_bonus_tier_granted`, see migration 0003 below) in one pass.
--
-- IDEMPOTENT / SAFE TO RE-RUN: `CREATE TABLE IF NOT EXISTS` is a no-op if
-- the table already exists in ANY shape (including a shape from an older
-- version of this migration file, or from install.sql itself already
-- having created it) -- this statement never ALTERs, never DROPs, never
-- touches existing rows. Running this against a database that already has
-- `k9_partnerships` (with or without `tenure_bonus_tier_granted`) is a
-- guaranteed no-op; running it against a database that has never had this
-- table creates it. Either way, running this file twice, or after
-- install.sql, or before install.sql, produces the identical end state.
--
-- SHAPE: byte-for-byte the same table definition documented in
-- `john-k9/sql/install.sql`'s own `k9_partnerships` header comment
-- (read that comment for the full design rationale -- not repeated here to
-- avoid two copies drifting out of sync) -- INCLUDING `tenure_bonus_tier_granted`,
-- so a database that goes straight from "no k9_partnerships table at all"
-- to running this migration file lands directly in final shape and does
-- NOT also need migration 0003 afterward (0003's own header documents this
-- same point from the other direction: it is a no-op if this file already
-- created the column).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_partnerships` (
  `id`                  INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `k9_citizenid`        VARCHAR(50)  NOT NULL,
  `handler_citizenid`   VARCHAR(50)  NOT NULL,
  `established_by`      VARCHAR(50)  NOT NULL,
  `established_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `ended_by`            VARCHAR(50)  DEFAULT NULL,
  `ended_at`            DATETIME     DEFAULT NULL,
  `active`              TINYINT(1)   NOT NULL DEFAULT 1,

  `tenure_bonus_tier_granted` TINYINT UNSIGNED NOT NULL DEFAULT 0,

  `active_partner_k9_key`      VARCHAR(50)
                                  GENERATED ALWAYS AS (
                                    CASE WHEN `active` = 1
                                         THEN `k9_citizenid`
                                         ELSE NULL
                                    END
                                  ) VIRTUAL,
  `active_partner_handler_key` VARCHAR(50)
                                  GENERATED ALWAYS AS (
                                    CASE WHEN `active` = 1
                                         THEN `handler_citizenid`
                                         ELSE NULL
                                    END
                                  ) VIRTUAL,

  PRIMARY KEY (`id`),
  KEY `idx_k9_citizenid_active` (`k9_citizenid`, `active`),
  KEY `idx_handler_citizenid_active` (`handler_citizenid`, `active`),
  UNIQUE KEY `uq_one_active_partnership_per_k9` (`active_partner_k9_key`),
  UNIQUE KEY `uq_one_active_partnership_per_handler` (`active_partner_handler_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
