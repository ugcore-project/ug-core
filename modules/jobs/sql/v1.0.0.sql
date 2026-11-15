CREATE TABLE IF NOT EXISTS `ug_character_jobs` (
    `character_id` INT UNSIGNED NOT NULL,
    `name` VARCHAR(32) NOT NULL,
    `grade` TINYINT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (`character_id`)
);
