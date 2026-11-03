-- mod-trading-post: the Traveler's Log pays at milestones, and its activities start small.

-- The last milestone paid, in points.
SET @tp_has_log_points := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'mod_trading_post_month' AND COLUMN_NAME = 'log_points');
SET @tp_add_log_points := IF(@tp_has_log_points = 0,
    'ALTER TABLE `mod_trading_post_month` ADD COLUMN `log_points` INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''the last milestone paid''',
    'SELECT 1');
PREPARE tp_statement FROM @tp_add_log_points;
EXECUTE tp_statement;
DEALLOCATE PREPARE tp_statement;

-- What's been done already counts for the new, smaller activities of the same kind. The ones that
-- were themed for a month (11xx) became activities of every month.
INSERT INTO `mod_trading_post_progress` (`account`, `month`, `activity`, `progress`)
SELECT p.`account`, p.`month`, m.`new_id`, LEAST(p.`progress`, m.`amount`)
FROM `mod_trading_post_progress` p
JOIN (
              SELECT 1 AS `old_id`, 9 AS `new_id`, 25 AS `amount`
    UNION ALL SELECT 1, 10, 100
    UNION ALL SELECT 2, 11, 1
    UNION ALL SELECT 2, 12, 5
    UNION ALL SELECT 3, 13, 1
    UNION ALL SELECT 4, 14, 1
    UNION ALL SELECT 4, 15, 5
    UNION ALL SELECT 5, 16, 1
    UNION ALL SELECT 6, 17, 1
    UNION ALL SELECT 6, 18, 10
    UNION ALL SELECT 7, 19, 10
    UNION ALL SELECT 8, 37, 5
    UNION ALL SELECT 1101, 35, 1
    UNION ALL SELECT 1102, 36, 5
    UNION ALL SELECT 1103, 23, 25
    UNION ALL SELECT 1104, 24, 25
    UNION ALL SELECT 1105, 25, 25
    UNION ALL SELECT 1106, 26, 15
    UNION ALL SELECT 1107, 27, 15
    UNION ALL SELECT 1108, 28, 10
    UNION ALL SELECT 1109, 29, 10
) m ON m.`old_id` = p.`activity`
ON DUPLICATE KEY UPDATE `progress` = GREATEST(`mod_trading_post_progress`.`progress`, VALUES(`progress`));
