CREATE TABLE IF NOT EXISTS `ug_characters` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `identifier` VARCHAR(64) NOT NULL,
    `name` VARCHAR(64) NOT NULL,
    `data` LONGTEXT NOT NULL,
    `death` LONGTEXT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_played` TIMESTAMP NULL,
    `deleted_at` TIMESTAMP NULL,
    PRIMARY KEY (`id`),
    KEY `identifier` (`identifier`)
);
