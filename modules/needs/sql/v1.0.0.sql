-- Needs of a character as JSON { [name] = value }.
CREATE TABLE IF NOT EXISTS `ug_needs` (
    `character_id` INT UNSIGNED NOT NULL,
    `data` VARCHAR(1024) NOT NULL,
    PRIMARY KEY (`character_id`)
);
