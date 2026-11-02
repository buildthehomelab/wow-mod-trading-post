-- mod-trading-post: undo the module's world database changes. Run it by hand on the world database
-- after removing the module. It isn't applied automatically: AzerothCore only runs the module's
-- db-world and db-characters folders. Idempotent: safe to run again.

DELETE FROM `creature` WHERE `guid` IN (9509000, 9509001);
DELETE FROM `creature_template_model` WHERE `CreatureID` IN (9509000, 9509001);
DELETE FROM `creature_template` WHERE `entry` IN (9509000, 9509001);
DELETE FROM `gossip_menu` WHERE `MenuID` = 9509000;
DELETE FROM `npc_text` WHERE `ID` = 9509000;
DROP TABLE IF EXISTS `mod_trading_post_activity`;
DROP TABLE IF EXISTS `mod_trading_post_stock`;
DROP TABLE IF EXISTS `mod_trading_post_theme`;
DELETE FROM `updates` WHERE `name` LIKE 'mod_trading_post%';
