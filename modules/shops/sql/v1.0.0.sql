CREATE TABLE IF NOT EXISTS `ug_shop_stock` (
    `shop` VARCHAR(48) NOT NULL,
    `item` VARCHAR(64) NOT NULL,
    `stock` INT UNSIGNED NOT NULL,
    `restocked_at` BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (`shop`, `item`)
);
