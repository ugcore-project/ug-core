CREATE TABLE IF NOT EXISTS `ug_accounts` (
    `character_id` INT UNSIGNED NOT NULL,
    `account` VARCHAR(32) NOT NULL,
    `balance` BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (`character_id`, `account`)
);

CREATE TABLE IF NOT EXISTS `ug_ledger` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `character_id` INT UNSIGNED NOT NULL,
    `account` VARCHAR(32) NOT NULL,
    `amount` BIGINT NOT NULL,
    `balance_after` BIGINT NOT NULL,
    `reason` VARCHAR(128) NULL,
    `related_character_id` INT UNSIGNED NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `character_account` (`character_id`, `account`, `id`)
);
