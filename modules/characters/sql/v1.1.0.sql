-- Last position of a character as JSON { x, y, z, heading }, read from the ped on the server.
ALTER TABLE `ug_characters` ADD COLUMN `position` VARCHAR(128) NULL AFTER `death`;
