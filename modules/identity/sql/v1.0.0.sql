CREATE TABLE IF NOT EXISTS `ug_bans` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `reason` VARCHAR(255) NULL,
    `banned_by` VARCHAR(64) NULL,
    `expires_at` DATETIME NULL,
    `revoked_at` DATETIME NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
);

CREATE TABLE IF NOT EXISTS `ug_ban_identifiers` (
    `ban_id` INT UNSIGNED NOT NULL,
    `identifier` VARCHAR(64) NOT NULL,
    PRIMARY KEY (`ban_id`, `identifier`),
    KEY `identifier` (`identifier`),
    CONSTRAINT `ug_ban_identifiers_ban` FOREIGN KEY (`ban_id`) REFERENCES `ug_bans` (`id`) ON DELETE CASCADE
);
