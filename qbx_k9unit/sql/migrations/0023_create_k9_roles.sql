-- =====================================================================
-- qbx_k9unit :: migration 0023 :: create k9_roles
--
-- WHO NEEDS THIS FILE: an existing installation whose sql/install.sql was
-- applied before `k9_roles` existed in it. A brand-new install does not
-- need it -- sql/install.sql creates the same table. Running it anyway is
-- always safe (CREATE TABLE IF NOT EXISTS).
--
-- WHAT IT IS FOR: the K9 role catalog high command edits on the tablet
-- (server/roles.lua) -- each role's label, the XP it switches on at, and
-- what it unlocks. See sql/install.sql's own k9_roles block for the full
-- description. Without this table the catalog still works for the session
-- (server/datastore.lua falls back to memory) but tablet edits are lost on
-- restart.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_roles` (
  `role_key`     VARCHAR(32)  NOT NULL,
  `label`        VARCHAR(60)  NOT NULL,
  `xp_required`  INT          NOT NULL DEFAULT 0,
  `unlocks`      VARCHAR(255) NOT NULL DEFAULT '',
  `deleted`      TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`   VARCHAR(50)  NOT NULL,
  `updated_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`role_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
