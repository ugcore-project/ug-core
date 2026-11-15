CREATE TABLE IF NOT EXISTS `ug_weapon_serials` (
    `serial` VARCHAR(16) NOT NULL,
    `item` VARCHAR(64) NOT NULL,
    `character_id` INT UNSIGNED NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`serial`),
    INDEX `idx_weapon_serials_character` (`character_id`)
);
