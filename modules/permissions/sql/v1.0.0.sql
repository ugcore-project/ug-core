CREATE TABLE IF NOT EXISTS `ug_permissions` (
    `identifier` VARCHAR(64) NOT NULL,
    `permission` VARCHAR(64) NOT NULL,
    `granted_by` VARCHAR(64) NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`, `permission`)
);
