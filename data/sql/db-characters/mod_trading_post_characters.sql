-- mod-trading-post: Trader's Tender and each account's month.

CREATE TABLE IF NOT EXISTS `mod_trading_post_wallet` (
  `account` INT UNSIGNED NOT NULL,
  `tender` INT NOT NULL DEFAULT 0,
  PRIMARY KEY (`account`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `mod_trading_post_ledger` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `at` BIGINT NOT NULL,
  `account` INT UNSIGNED NOT NULL,
  `guid` INT UNSIGNED NOT NULL DEFAULT 0,
  `tender` INT NOT NULL,
  `balance` INT UNSIGNED NOT NULL,
  `reason` VARCHAR(16) NOT NULL,
  `item` INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  KEY `account` (`account`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `mod_trading_post_month` (
  `account` INT UNSIGNED NOT NULL,
  `month` INT UNSIGNED NOT NULL COMMENT '202611',
  `cache_taken` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `log_paid` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`account`, `month`),
  KEY `month` (`month`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `mod_trading_post_progress` (
  `account` INT UNSIGNED NOT NULL,
  `month` INT UNSIGNED NOT NULL,
  `activity` INT UNSIGNED NOT NULL,
  `progress` INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`account`, `month`, `activity`),
  KEY `month` (`month`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `mod_trading_post_purchase` (
  `account` INT UNSIGNED NOT NULL,
  `item` INT UNSIGNED NOT NULL,
  `at` BIGINT NOT NULL,
  `price` INT UNSIGNED NOT NULL DEFAULT 0,
  `guid` INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'who a mailed purchase goes to',
  `delivered` TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '0: paid, the mail has not gone yet',
  PRIMARY KEY (`account`, `item`),
  KEY `delivered` (`delivered`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- A purchase table from before mailed goods waited for their payment to be written.
SET @tp_has_delivered := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'mod_trading_post_purchase' AND COLUMN_NAME = 'delivered');
SET @tp_add_delivered := IF(@tp_has_delivered = 0,
    'ALTER TABLE `mod_trading_post_purchase` ADD COLUMN `guid` INT UNSIGNED NOT NULL DEFAULT 0, ADD COLUMN `delivered` TINYINT UNSIGNED NOT NULL DEFAULT 1, ADD KEY `delivered` (`delivered`)',
    'SELECT 1');
PREPARE tp_statement FROM @tp_add_delivered;
EXECUTE tp_statement;
DEALLOCATE PREPARE tp_statement;

CREATE TABLE IF NOT EXISTS `mod_trading_post_frozen` (
  `account` INT UNSIGNED NOT NULL,
  `item` INT UNSIGNED NOT NULL,
  `month` INT UNSIGNED NOT NULL COMMENT 'when it was frozen',
  PRIMARY KEY (`account`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
