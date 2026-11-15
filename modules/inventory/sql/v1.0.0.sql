CREATE TABLE IF NOT EXISTS `ug_inventories` (
    `id` VARCHAR(96) NOT NULL,
    `items` LONGTEXT NOT NULL,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
);

CREATE TABLE IF NOT EXISTS `ug_item_logs` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `inventory` VARCHAR(96) NOT NULL,
    `item` VARCHAR(64) NOT NULL,
    `amount` INT NOT NULL,
    `metadata` LONGTEXT NULL,
    `reason` VARCHAR(128) NULL,
    `related` VARCHAR(96) NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    INDEX `idx_item_logs_inventory` (`inventory`, `id`)
);
