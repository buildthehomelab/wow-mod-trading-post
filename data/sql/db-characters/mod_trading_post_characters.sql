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
  PRIMARY KEY (`account`, `item`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `mod_trading_post_frozen` (
  `account` INT UNSIGNED NOT NULL,
  `item` INT UNSIGNED NOT NULL,
  `month` INT UNSIGNED NOT NULL COMMENT 'when it was frozen',
  PRIMARY KEY (`account`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
