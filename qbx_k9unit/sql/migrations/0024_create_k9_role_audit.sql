-- =====================================================================
-- qbx_k9unit :: migration 0024 :: create k9_role_audit
--
-- WHO NEEDS THIS FILE: an existing installation whose sql/install.sql was
-- applied before `k9_role_audit` existed in it. A brand-new install does
-- not need it -- sql/install.sql creates the same table. Running it anyway
-- is always safe (CREATE TABLE IF NOT EXISTS).
--
-- WHAT IT IS FOR: the history of every role edit high command makes on
-- the tablet (server/roles.lua), shown on the Audit Trail under Catalog
-- Changes. Without this table the history is kept in memory for the
-- session only.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_role_audit` (
  `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`       VARCHAR(20)  NOT NULL,
  `role_key`     VARCHAR(32)  NOT NULL,
  `detail`       TEXT         NOT NULL,
  `changed_by`   VARCHAR(50)  NOT NULL,
  `changed_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  KEY `idx_role_changed_at` (`role_key`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
