CREATE TABLE IF NOT EXISTS `ug_group_members` (
    `identifier` VARCHAR(64) NOT NULL,
    `group_name` VARCHAR(32) NOT NULL,
    `added_by` VARCHAR(64) NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`, `group_name`)
);
