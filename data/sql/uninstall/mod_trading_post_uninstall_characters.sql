-- mod-trading-post: undo the module's characters database changes. Run it by hand after removing
-- the module. This forgets every account's Trader's Tender and purchases; what was bought stays
-- known by the characters. Idempotent: safe to run again.

DROP TABLE IF EXISTS `mod_trading_post_frozen`;
DROP TABLE IF EXISTS `mod_trading_post_purchase`;
DROP TABLE IF EXISTS `mod_trading_post_progress`;
DROP TABLE IF EXISTS `mod_trading_post_month`;
DROP TABLE IF EXISTS `mod_trading_post_ledger`;
DROP TABLE IF EXISTS `mod_trading_post_wallet`;
DELETE FROM `updates` WHERE `name` LIKE 'mod_trading_post%';
