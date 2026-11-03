/*
 * mod-trading-post: the Traveler's Log, Trader's Tender and the proprietors' stock.
 *
 * The month is the server's local calendar month, and its theme is the month's number, so twelve
 * themes come round again every year. Hooks on the map threads count activity under one lock, and
 * the writes they cause wait for the world thread (Update): progress goes out every so often, a
 * milestone's reward as soon as it's earned.
 *
 *   world       mod_trading_post_theme, _stock, _activity
 *   characters  mod_trading_post_wallet, _ledger     account -> Tender, and every change
 *               mod_trading_post_month, _progress    this month's claims and activity
 *               mod_trading_post_purchase, _frozen   what the account bought and holds over
 *
 * Addon messages are whispers to oneself on prefix TPOST, one row each:
 *   client   HELLO:<protocol>  STATE  LOG  STOCK  CACHE  BUY:<item>  FREEZE:<item, 0 thaws>  R:<creature>
 *   server   H:<protocol>      the hello's answer
 *            G:<points>:<tender>:<points>:<tender>...   the log's milestones
 *            S:<balance>:<month>:<points>:<needed>:<cache taken>:<log done>:<cache pays>:<log pays>:<seconds left>:<frozen>:<bonus item>
 *            T:<theme>^<description>
 *            LA:<id>^<amount>^<progress>^<points>^<name>^<description>   LE    the activity list
 *            P:<id>:<progress>:<month's points>                                one activity moved
 *            SI:<item>^<price>^<status>^<frozen>^<creature>^<kind>^<unlock>  SE    the stock
 *            OPEN  M           open the shop; a new month
 *            B:<item>:<1 bought, 0 not>  C:<1, 0>  F:<item>                results
 *            E:<text>          why something was refused
 *
 * Released under the MIT License.
 */

#include "TradingPost.h"

#if __has_include("ChallengesApi.h")
#include "ChallengesApi.h"
#endif

#include "AsyncCallbackProcessor.h"
#include "Chat.h"
#include "Config.h"
#include "Creature.h"
#include "DatabaseEnv.h"
#include "DBCStores.h"
#include "GameTime.h"
#include "Item.h"
#include "Log.h"
#include "Mail.h"
#include "MailMgr.h"
#include "ObjectAccessor.h"
#include "ObjectMgr.h"
#include "Opcodes.h"
#include "Player.h"
#include "QueryResult.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "Timer.h"
#include "Tokenize.h"
#include "WorldPacket.h"
#include "WorldSession.h"
#include "WorldSessionMgr.h"

// A core with home screens keeps a character row per account that nobody plays. Other cores have none.
#if __has_include("HomeViewer.h")
#include "HomeViewer.h"
#else
#define SQL_NOT_HOME_VIEWER "1"
inline bool IsHomeViewer(Player const*) { return false; }
#endif

#include <algorithm>
#include <charconv>
#include <ctime>
#include <limits>
#include <map>
#include <mutex>
#include <set>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace TradingPost;

namespace
{
    constexpr uint32 PROGRESSION_QUEST = 66000;     // mod-individual-progression: 66000 + phase, rewarded
    constexpr uint8 PROGRESSION_LAST_PHASE = 18;
    constexpr uint8 PROGRESSION_TBC_PHASE = 8;
    constexpr uint8 PROGRESSION_WOTLK_PHASE = 13;
    constexpr uint32 NPC_MAIL_SENDER = 9509000;
    constexpr uint32 MAIL_DAYS = 180;
    constexpr uint32 MONTH_CHECK_MS = 30 * IN_MILLISECONDS;
    constexpr uint32 MAX_TENDER = 10000000;
    // Addon messages that read the database: this many a window. A click makes one or two.
    constexpr uint32 COSTLY_REQUESTS = 8;
    constexpr uint32 COSTLY_WINDOW_MS = 2 * IN_MILLISECONDS;

    enum AccountKind : uint8 { KIND_NONE, KIND_MOUNT, KIND_PET };
    constexpr char const* ACCOUNT_TABLES[] = { "", "accountwide_mounts", "accountwide_pets" };

    // DragonUI's Currency tab lists what a server keeps outside the bags, sent as addon whispers with
    // this prefix. The item gives the row its icon and tooltip.
    constexpr char const* CURRENCY_PREFIX = DRAGONUI_CURRENCY_PREFIX;
    constexpr char const* CURRENCY_SECTION = "Account Wallet";
    constexpr char const* CURRENCY_NAME = "Trader's Tender";

    enum StockStatus : uint8 { STATUS_FOR_SALE, STATUS_OWNED, STATUS_LOCKED, STATUS_SELF_FOUND };

    struct Milestone
    {
        uint32 points = 0;
        uint32 tender = 0;
    };

    constexpr char const* DEFAULT_MILESTONES = "250:100,500:100,750:100,1000:200";

    struct Settings
    {
        bool enabled = true;
        uint32 cacheTender = 500;
        std::vector<Milestone> milestones;      // ascending, never empty once loaded; under stateLock
        uint32 logTender = 500;                 // all of them together
        uint32 logPoints = 1000;                // the last one, which completes the log
        uint32 flushMs = 30 * IN_MILLISECONDS;
        bool accountWide = true;
        bool progressionGate = true;
        uint32 progressionLimit = 0;
        uint32 currencyItem = 37711;
    } settings;

    struct Theme
    {
        std::string name;
        std::string description;
        uint32 bonusItem = 0;
    };

    struct Goods
    {
        uint32 item = 0;
        uint32 price = 0;
        uint8 phase = 0;
        uint16 sort = 0;
    };

    // What an item teaches, worked out once for every item the module sells or gives away.
    struct ItemInfo
    {
        std::string name;
        uint32 teaches = 0;
        uint32 creature = 0;
        uint8 kind = KIND_NONE;
    };

    struct Activity
    {
        uint32 id = 0;
        uint8 type = 0;
        uint32 target = 0;
        uint32 amount = 0;
        uint32 points = 0;
        uint16 sort = 0;
        std::string name;
        std::string description;
    };

    struct AccountMonth
    {
        std::unordered_map<uint32, uint32> progress;
        uint32 points = 0;
        bool cacheTaken = false;
        uint32 paidPoints = 0;      // the last milestone queued, so that it's only queued once
        bool logPaid = false;       // the last milestone of all is
    };

    // The month and its bonus are kept with the reward: it can still be waiting when the month ends.
    // Milestones reached together are one reward.
    struct PendingReward
    {
        uint32 account = 0;
        uint32 guid = 0;
        uint32 month = 0;
        uint32 tender = 0;
        uint32 paidPoints = 0;
        bool last = false;          // completes the log
        uint32 bonus = 0;
    };

    struct FailedMail
    {
        uint32 account = 0;
        uint32 guid = 0;
        uint32 item = 0;
        ItemInfo info;
    };

    // Everything below is guarded by stateLock, except what only the world thread touches, which
    // says so. No query or packet goes out while it's held.
    std::mutex stateLock;
    Theme themes[MAX_THEME + 1];
    std::vector<Goods> stock[MAX_THEME + 1];
    std::unordered_map<uint32, ItemInfo> itemInfo;
    std::vector<Activity> monthActivities;
    std::vector<Activity const*> activitiesByType[MAX_ACTIVITY_TYPE];
    uint32 currentMonth = 0;            // 202611
    uint8 currentTheme = 0;             // 11
    std::unordered_map<uint32, uint32> balances;
    std::unordered_map<uint32, std::unordered_set<uint32>> purchases;
    std::unordered_map<uint32, uint32> frozen;
    std::unordered_map<uint32, AccountMonth> accounts;
    std::set<std::pair<uint32, uint32>> dirtyProgress;      // account, activity
    std::vector<PendingReward> pendingRewards;
    std::unordered_set<uint32> addonPlayers;                // character guid
    std::unordered_map<uint32, ObjectGuid> shopNpc;         // character guid -> the proprietor
    std::unordered_set<uint32> ordersInFlight;              // account
    std::unordered_set<uint32> previewCreatures;
    struct RequestWindow { uint32 start = 0; uint32 count = 0; };
    std::unordered_map<uint32, RequestWindow> costlyRequests;   // character guid

    // World thread only.
    bool accountTables[3] = { false, false, false };
    bool progressionQuests = false;
    uint32 flushTimer = 0;
    uint32 monthTimer = 0;
    std::vector<PendingReward> failedRewards;       // their write failed; tried again with the next save
    std::unordered_set<uint32> rewardsInFlight;     // account: a reward being written, or failed and waiting
    std::vector<FailedMail> failedMails;            // likewise
    AsyncCallbackProcessor<TransactionCallback> commits;

    uint32 MonthOf(time_t when)
    {
        std::tm const local = Acore::Time::TimeBreakdown(when);
        return uint32(local.tm_year + 1900) * 100 + uint32(local.tm_mon + 1);
    }

    uint32 SecondsLeftInMonth()
    {
        time_t const now = GameTime::GetGameTime().count();
        std::tm next = Acore::Time::TimeBreakdown(now);
        next.tm_mon += 1;   // mktime carries December into January
        next.tm_mday = 1;
        next.tm_hour = next.tm_min = next.tm_sec = 0;
        next.tm_isdst = -1;
        time_t const end = std::mktime(&next);
        return end > now ? uint32(end - now) : 0;
    }

    bool IsSelfFound(uint32 guid)
    {
#if __has_include("ChallengesApi.h")
        return Challenges::IsSelfFound(guid);
#else
        (void)guid;
        return false;
#endif
    }

    // The separator of a row can't be part of its text.
    std::string Clean(std::string text)
    {
        std::replace(text.begin(), text.end(), '^', '/');
        return text;
    }

    bool ParseUInt(std::string_view text, uint32& value)
    {
        auto const [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
        return error == std::errc() && end == text.data() + text.size();
    }

    // "250:100,500:100": ascending points, each with the Tender it pays.
    std::vector<Milestone> ParseMilestones(std::string const& text)
    {
        std::vector<Milestone> parsed;
        for (std::string_view entry : Acore::Tokenize(text, ',', false))
        {
            size_t const colon = entry.find(':');
            Milestone milestone;
            if (colon == std::string_view::npos || !ParseUInt(entry.substr(0, colon), milestone.points)
                || !ParseUInt(entry.substr(colon + 1), milestone.tender) || !milestone.points
                || (!parsed.empty() && milestone.points <= parsed.back().points))
                return {};
            parsed.push_back(milestone);
        }
        return parsed;
    }

    void Send(Player* player, std::string const& payload)
    {
        if (!player || !player->GetSession())
            return;

        WorldPacket data;
        ChatHandler::BuildChatPacket(data, CHAT_MSG_WHISPER, LANG_ADDON, player, player, std::string(PREFIX) + "\t" + payload);
        player->GetSession()->SendPacket(&data);
    }

    // The player of the session that plays for this account, if any.
    Player* AccountPlayer(uint32 account)
    {
        WorldSession* session = sWorldSessionMgr->FindSession(account);
        Player* player = session ? session->GetPlayer() : nullptr;
        return player && !session->PlayerLoading() && IsRealPlayer(player) ? player : nullptr;
    }

    void Record(CharacterDatabaseTransaction trans, uint32 account, uint32 guid, int64 change, uint32 balance,
        std::string_view reason, uint32 item)
    {
        trans->Append("INSERT INTO mod_trading_post_wallet (account, tender) VALUES ({}, {}) "
            "ON DUPLICATE KEY UPDATE tender = tender + {}", account, change, change);
        trans->Append("INSERT INTO mod_trading_post_ledger (at, account, guid, tender, balance, reason, item) "
            "VALUES ({}, {}, {}, {}, {}, '{}', {})",
            GameTime::GetGameTime().count(), account, guid, change, balance, reason, item);
    }

    uint32 Pay(uint32 account, uint32 tender)
    {
        std::lock_guard<std::mutex> guard(stateLock);
        uint32& balance = balances[account];
        balance = uint32(std::min<uint64>(uint64(balance) + tender, MAX_TENDER));
        return balance;
    }

    bool SharedWithAccount(ItemInfo const& info)
    {
        return settings.accountWide && info.kind != KIND_NONE && accountTables[info.kind];
    }

    // In the transaction that pays. A shared mount or pet goes into the sharing module's table right
    // there. Anything else is mailed once that transaction is written (MailPurchase), so a failed
    // payment never leaves a free item. `delivered` says the mail hasn't gone yet, for the next
    // startup to finish.
    void RecordPurchase(CharacterDatabaseTransaction trans, uint32 account, uint32 guid, uint32 item, ItemInfo const& info, uint32 price, bool shared)
    {
        trans->Append("INSERT IGNORE INTO mod_trading_post_purchase (account, item, at, price, guid, delivered) VALUES ({}, {}, {}, {}, {}, {})",
            account, item, GameTime::GetGameTime().count(), price, guid, shared ? 1 : 0);
        if (shared)
            trans->Append("INSERT IGNORE INTO {} (account_id, spell) VALUES ({}, {})", ACCOUNT_TABLES[info.kind], account, info.teaches);
    }

    void MailPurchase(uint32 account, uint32 guid, uint32 item, ItemInfo const& info)
    {
        // An account with no character left has nobody to mail: the row waits for a later startup.
        if (!guid)
            return;

        Item* mailed = Item::CreateItem(item, 1, nullptr);
        if (!mailed)
        {
            LOG_ERROR("module", "mod-trading-post: could not make item {} to mail to account {}", item, account);
            return;
        }

        // Not MailDraft: it fills an online character's mailbox before the write is done. A write
        // that then failed would leave a mail they can empty and a row that sends it again. Here
        // the mailbox hears of it once it's written, so `delivered` is always the truth.
        ObjectGuid const receiver = ObjectGuid::Create<HighGuid::Player>(guid);
        mailed->SetOwnerGUID(receiver);

        uint32 const mailId = sObjectMgr->GenerateMailID();
        time_t const deliverTime = GameTime::GetGameTime().count();
        time_t const expireTime = deliverTime + MAIL_DAYS * DAY;
        std::string const subject = fmt::format("Your order: {}", info.name);
        std::string const body = fmt::format("Here's your {}. Pleasure doing business.\n\n-- The Trading Post", info.name);

        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        mailed->SaveToDB(trans);

        uint8 index = 0;
        CharacterDatabasePreparedStatement* stmt = CharacterDatabase.GetPreparedStatement(CHAR_INS_MAIL);
        stmt->SetData(  index, mailId);
        stmt->SetData(++index, uint8(MAIL_CREATURE));
        stmt->SetData(++index, int8(MAIL_STATIONERY_DEFAULT));
        stmt->SetData(++index, uint16(0));
        stmt->SetData(++index, NPC_MAIL_SENDER);
        stmt->SetData(++index, guid);
        stmt->SetData(++index, subject);
        stmt->SetData(++index, body);
        stmt->SetData(++index, true);
        stmt->SetData(++index, uint32(expireTime));
        stmt->SetData(++index, uint32(deliverTime));
        stmt->SetData(++index, uint32(0));
        stmt->SetData(++index, uint32(0));
        stmt->SetData(++index, uint8(MAIL_CHECK_MASK_NONE));
        trans->Append(stmt);

        stmt = CharacterDatabase.GetPreparedStatement(CHAR_INS_MAIL_ITEM);
        stmt->SetData(0, mailId);
        stmt->SetData(1, mailed->GetGUID().GetCounter());
        stmt->SetData(2, guid);
        trans->Append(stmt);

        trans->Append("UPDATE mod_trading_post_purchase SET delivered = 1 WHERE account = {} AND item = {}", account, item);
        commits.AddCallback(CharacterDatabase.AsyncCommitTransaction(trans)).AfterComplete(
            [account, guid, item, info, receiver, mailed, mailId, deliverTime, expireTime, subject, body](bool success)
        {
            if (!success)
            {
                delete mailed;
                failedMails.push_back({ account, guid, item, info });
                LOG_ERROR("module", "mod-trading-post: the mail with item {} for account {} could not be saved; will try again", item, account);
                return;
            }

            sMailMgr->OnMailSent(guid);

            // Offline, or logged in just now and read it from the database: its next load has it.
            Player* online = ObjectAccessor::FindConnectedPlayer(receiver);
            if (!online || online->GetMail(mailId))
            {
                delete mailed;
                return;
            }

            Mail* mail = new Mail;
            mail->messageID = mailId;
            mail->mailTemplateId = 0;
            mail->subject = subject;
            mail->body = body;
            mail->money = 0;
            mail->COD = 0;
            mail->AddItem(mailed->GetGUID().GetCounter(), mailed->GetEntry());
            mail->messageType = MAIL_CREATURE;
            mail->stationery = MAIL_STATIONERY_DEFAULT;
            mail->sender = NPC_MAIL_SENDER;
            mail->receiver = guid;
            mail->expire_time = expireTime;
            mail->deliver_time = deliverTime;
            mail->checked = MAIL_CHECK_MASK_NONE;
            mail->state = MAIL_STATE_UNCHANGED;

            online->AddMail(mail);
            online->AddMItem(mailed);
            online->AddNewMailDeliverTime(deliverTime);
        });
    }

    // After the write is done: the character in the game learns what its account now has. Later
    // logins learn it from the sharing module's table.
    void TeachOnline(uint32 account, ItemInfo const& info)
    {
        if (!SharedWithAccount(info))
            return;
        Player* player = AccountPlayer(account);
        if (player && !IsSelfFound(player->GetGUID().GetCounter()) && !player->HasSpell(info.teaches))
            player->learnSpell(info.teaches);
    }

    // The account's progression: that of its furthest character. The character in the game is
    // asked directly, as the database has only its last save.
    uint8 AccountPhase(Player* player)
    {
        uint8 phase = 0;
        for (uint8 p = PROGRESSION_LAST_PHASE; p > 0; --p)
            if (player->GetQuestRewardStatus(PROGRESSION_QUEST + p))
            {
                phase = p;
                break;
            }

        if (QueryResult result = CharacterDatabase.Query("SELECT MAX(q.quest) FROM character_queststatus_rewarded q "
            "JOIN characters c ON c.guid = q.guid WHERE c.account = {} AND q.quest BETWEEN {} AND {} AND q.active = 1",
            player->GetSession()->GetAccountId(), PROGRESSION_QUEST + 1, PROGRESSION_QUEST + PROGRESSION_LAST_PHASE))
            if (!result->Fetch()[0].IsNull())
                phase = std::max<uint8>(phase, uint8(result->Fetch()[0].Get<uint32>() - PROGRESSION_QUEST));

        return phase;
    }

    bool LockedByPhase(uint8 phase, uint8 accountPhase)
    {
        return settings.progressionGate && progressionQuests && phase > accountPhase;
    }

    std::string UnlockText(uint8 phase)
    {
        char const* era = phase >= PROGRESSION_WOTLK_PHASE ? "Wrath of the Lich King"
            : phase >= PROGRESSION_TBC_PHASE ? "The Burning Crusade" : nullptr;
        if (settings.progressionLimit && phase > settings.progressionLimit && era)
            return fmt::format("Comes to the realm with {}.", era);
        if (era)
            return fmt::format("Reach {} with any character to unlock it.", era);
        return "Progress further with any character to unlock it.";
    }

    // The sharing modules' spells, plus what the module itself sold: both count as owned.
    std::unordered_set<uint32> AccountSpells(uint32 account)
    {
        std::unordered_set<uint32> spells;
        if (!settings.accountWide)
            return spells;
        for (uint8 kind = KIND_MOUNT; kind <= KIND_PET; ++kind)
            if (accountTables[kind])
                if (QueryResult result = CharacterDatabase.Query("SELECT spell FROM {} WHERE account_id = {}", ACCOUNT_TABLES[kind], account))
                    do
                        spells.insert(result->Fetch()[0].Get<uint32>());
                    while (result->NextRow());
        return spells;
    }

    bool Owned(Player* player, uint32 item, ItemInfo const& info, std::unordered_set<uint32> const& bought,
        std::unordered_set<uint32> const& spells)
    {
        return bought.count(item) || (info.teaches && (spells.count(info.teaches) || player->HasSpell(info.teaches)));
    }

    bool AtShop(Player* player)
    {
        ObjectGuid npc;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            auto itr = shopNpc.find(player->GetGUID().GetCounter());
            if (itr == shopNpc.end())
                return false;
            npc = itr->second;
        }
        return player->GetNPCIfCanInteractWith(npc, UNIT_NPC_FLAG_GOSSIP) != nullptr;
    }

    bool TooSoon(Player* player)
    {
        uint32 const guid = player->GetGUID().GetCounter();
        uint32 const now = getMSTime();
        std::lock_guard<std::mutex> guard(stateLock);
        RequestWindow& window = costlyRequests[guid];
        if (!window.count || getMSTimeDiff(window.start, now) >= COSTLY_WINDOW_MS)
        {
            window.start = now;
            window.count = 0;
        }
        return ++window.count > COSTLY_REQUESTS;
    }

    void SendItemDetails(Player* player, uint32 item)
    {
        // A 3.3.5 client that has never seen an item shows it nameless and without an icon, and
        // an addon has no way to ask. The answer it would get to asking goes out unasked.
        WorldPacket query(CMSG_ITEM_QUERY_SINGLE, 4);
        query << item;
        player->GetSession()->HandleItemQuerySingleOpcode(query);
    }

    void SendState(Player* player)
    {
        uint32 const account = player->GetSession()->GetAccountId();
        uint32 balance, month, points = 0, frozenItem = 0, bonus;
        std::string milestones = "G";
        bool cacheTaken = false, logPaid = false;
        std::string themeName, themeDescription;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            auto wallet = balances.find(account);
            balance = wallet != balances.end() ? wallet->second : 0;
            month = currentMonth;
            if (auto itr = accounts.find(account); itr != accounts.end())
            {
                points = itr->second.points;
                cacheTaken = itr->second.cacheTaken;
                logPaid = itr->second.logPaid;
            }
            if (auto itr = frozen.find(account); itr != frozen.end())
                frozenItem = itr->second;
            for (Milestone const& milestone : settings.milestones)
                milestones += fmt::format(":{}:{}", milestone.points, milestone.tender);
            bonus = themes[currentTheme].bonusItem;
            themeName = themes[currentTheme].name;
            themeDescription = themes[currentTheme].description;
        }

        if (bonus)
            SendItemDetails(player, bonus);
        if (frozenItem)
            SendItemDetails(player, frozenItem);
        Send(player, milestones);
        Send(player, fmt::format("S:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}", balance, month, points, settings.logPoints, cacheTaken ? 1 : 0,
            logPaid ? 1 : 0, settings.cacheTender, settings.logTender, SecondsLeftInMonth(), frozenItem, bonus));
        Send(player, fmt::format("T:{}^{}", Clean(themeName), Clean(themeDescription)));
    }

    void SendLog(Player* player)
    {
        uint32 const account = player->GetSession()->GetAccountId();
        std::vector<std::string> rows;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            AccountMonth const* state = nullptr;
            if (auto itr = accounts.find(account); itr != accounts.end())
                state = &itr->second;
            for (Activity const& activity : monthActivities)
            {
                uint32 progress = 0;
                if (state)
                    if (auto itr = state->progress.find(activity.id); itr != state->progress.end())
                        progress = itr->second;
                rows.push_back(fmt::format("LA:{}^{}^{}^{}^{}^{}", activity.id, activity.amount, progress, activity.points,
                    Clean(activity.name), Clean(activity.description)));
            }
        }
        for (std::string const& row : rows)
            Send(player, row);
        Send(player, "LE");
    }

    // The theme's goods plus the account's frozen item, which is on sale whatever the month.
    std::vector<Goods> GoodsFor(uint32 account)
    {
        std::vector<Goods> goods = stock[currentTheme];
        auto itr = frozen.find(account);
        if (itr == frozen.end())
            return goods;
        if (std::none_of(goods.begin(), goods.end(), [&](Goods const& g) { return g.item == itr->second; }))
            for (uint8 theme = 1; theme <= MAX_THEME; ++theme)
                for (Goods const& g : stock[theme])
                    if (g.item == itr->second)
                    {
                        goods.push_back(g);
                        return goods;
                    }
        return goods;
    }

    void SendStock(Player* player)
    {
        uint32 const account = player->GetSession()->GetAccountId();
        uint32 const guid = player->GetGUID().GetCounter();
        std::unordered_set<uint32> const spells = AccountSpells(account);
        uint8 const accountPhase = progressionQuests ? AccountPhase(player) : 0;
        bool const selfFound = IsSelfFound(guid);

        std::vector<std::string> rows;
        std::vector<uint32> items;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            uint32 const frozenItem = frozen.count(account) ? frozen[account] : 0;
            auto const& bought = purchases[account];
            for (Goods const& good : GoodsFor(account))
            {
                auto info = itemInfo.find(good.item);
                if (info == itemInfo.end())
                    continue;

                uint8 status = STATUS_FOR_SALE;
                if (Owned(player, good.item, info->second, bought, spells))
                    status = STATUS_OWNED;
                else if (LockedByPhase(good.phase, accountPhase))
                    status = STATUS_LOCKED;
                else if (selfFound)
                    status = STATUS_SELF_FOUND;

                items.push_back(good.item);
                rows.push_back(fmt::format("SI:{}^{}^{}^{}^{}^{}^{}", good.item, good.price, uint32(status), good.item == frozenItem ? 1 : 0,
                    info->second.creature, uint32(info->second.kind), status == STATUS_LOCKED ? UnlockText(good.phase) : ""));
            }
        }

        for (uint32 item : items)
            SendItemDetails(player, item);
        for (std::string const& row : rows)
            Send(player, row);
        Send(player, "SE");
    }

    void ClaimCache(Player* player)
    {
        uint32 const account = player->GetSession()->GetAccountId();
        uint32 const guid = player->GetGUID().GetCounter();
        if (IsSelfFound(guid))
        {
            Send(player, "E:Self-Found characters don't take from the Collector's Cache: Tender belongs to the account.");
            Send(player, "C:0");
            return;
        }

        uint32 month;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            AccountMonth& state = accounts[account];
            if (state.cacheTaken)
            {
                month = 0;
            }
            else
            {
                state.cacheTaken = true;
                month = currentMonth;
            }
        }
        if (!month)
        {
            Send(player, "C:0");
            return;
        }

        // Spendable once it's written, so nothing can be spent that a failed write takes back.
        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        Record(trans, account, guid, settings.cacheTender, Balance(account) + settings.cacheTender, "cache", 0);
        trans->Append("INSERT INTO mod_trading_post_month (account, month, cache_taken) VALUES ({}, {}, 1) "
            "ON DUPLICATE KEY UPDATE cache_taken = 1", account, month);
        commits.AddCallback(CharacterDatabase.AsyncCommitTransaction(trans)).AfterComplete(
            [account, month, amount = settings.cacheTender](bool success)
            {
                Player* player = AccountPlayer(account);
                if (success)
                    Pay(account, amount);
                else
                {
                    std::lock_guard<std::mutex> guard(stateLock);
                    if (currentMonth == month)
                        accounts[account].cacheTaken = false;
                    LOG_ERROR("module", "mod-trading-post: the Collector's Cache of account {} could not be saved", account);
                }
                if (player)
                {
                    Send(player, fmt::format("C:{}", success ? 1 : 0));
                    SendState(player);
                    TradingPost::SendCurrency(player);
                }
            });
    }

    void Refuse(Player* player, uint32 item, std::string_view why)
    {
        Send(player, fmt::format("E:{}", why));
        Send(player, fmt::format("B:{}:0", item));
    }

    void Buy(Player* player, uint32 item)
    {
        uint32 const account = player->GetSession()->GetAccountId();
        uint32 const guid = player->GetGUID().GetCounter();

        if (IsSelfFound(guid))
            return Refuse(player, item, "Self-Found characters can't buy from the Trading Post.");

        std::unordered_set<uint32> const spells = AccountSpells(account);
        uint8 const accountPhase = progressionQuests ? AccountPhase(player) : 0;

        Goods good;
        ItemInfo info;
        uint32 balance = 0;
        bool wasFrozen = false;
        std::string refused;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            std::vector<Goods> const goods = GoodsFor(account);
            auto const found = std::find_if(goods.begin(), goods.end(), [item](Goods const& g) { return g.item == item; });
            auto const known = itemInfo.find(item);
            if (ordersInFlight.count(account))
                refused = "Your last order is still being written up.";
            else if (found == goods.end() || known == itemInfo.end())
                refused = "That isn't on the shelves this month.";
            else if (Owned(player, item, known->second, purchases[account], spells))
                refused = "You already own that.";
            else if (LockedByPhase(found->phase, accountPhase))
                refused = UnlockText(found->phase);
            else if (balances[account] < found->price)
                refused = "You don't have enough Trader's Tender.";
            else
            {
                good = *found;
                info = known->second;
                balance = balances[account] -= good.price;
                purchases[account].insert(item);
                ordersInFlight.insert(account);
                auto ice = frozen.find(account);
                if (ice != frozen.end() && ice->second == item)
                {
                    wasFrozen = true;
                    frozen.erase(ice);
                }
            }
        }
        if (!refused.empty())
            return Refuse(player, item, refused);

        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        Record(trans, account, guid, -int64(good.price), balance, "buy", item);
        bool const shared = SharedWithAccount(info);
        RecordPurchase(trans, account, guid, item, info, good.price, shared);
        if (wasFrozen)
            trans->Append("DELETE FROM mod_trading_post_frozen WHERE account = {}", account);

        commits.AddCallback(CharacterDatabase.AsyncCommitTransaction(trans)).AfterComplete(
            [account, guid, item, info, shared, price = good.price, wasFrozen](bool success)
            {
                {
                    std::lock_guard<std::mutex> guard(stateLock);
                    ordersInFlight.erase(account);
                    if (!success)
                    {
                        balances[account] += price;
                        purchases[account].erase(item);
                        if (wasFrozen)
                            frozen.emplace(account, item);
                        LOG_ERROR("module", "mod-trading-post: account {}'s order for item {} could not be saved", account, item);
                    }
                }
                if (success)
                {
                    if (shared)
                        TeachOnline(account, info);
                    else
                        MailPurchase(account, guid, item, info);
                }
                if (Player* player = AccountPlayer(account))
                {
                    if (success)
                        ChatHandler(player->GetSession()).PSendSysMessage(shared
                            ? "The {} is yours now, on every character of your account."
                            : "The Trading Post has mailed you the {}. Check your mailbox.", info.name);
                    Send(player, fmt::format("B:{}:{}", item, success ? 1 : 0));
                    TradingPost::SendCurrency(player);
                }
            });
    }

    void Freeze(Player* player, uint32 item)
    {
        uint32 const account = player->GetSession()->GetAccountId();
        uint32 const guid = player->GetGUID().GetCounter();
        std::unordered_set<uint32> const spells = AccountSpells(account);
        uint8 const accountPhase = progressionQuests ? AccountPhase(player) : 0;

        std::string refused;
        uint32 month;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            month = currentMonth;
            if (item)
            {
                // Only this month's goods: holding on to one is the point of freezing it.
                auto const& goods = stock[currentTheme];
                auto const found = std::find_if(goods.begin(), goods.end(), [item](Goods const& g) { return g.item == item; });
                auto const known = itemInfo.find(item);
                if (found == goods.end() || known == itemInfo.end())
                    refused = "Only this month's goods can be frozen.";
                else if (Owned(player, item, known->second, purchases[account], spells))
                    refused = "You already own that.";
                else if (LockedByPhase(found->phase, accountPhase))
                    refused = UnlockText(found->phase);
                else if (IsSelfFound(guid))
                    refused = "Self-Found characters can't buy from the Trading Post.";
                else
                    frozen[account] = item;
            }
            else
                frozen.erase(account);
        }

        if (!refused.empty())
        {
            Send(player, fmt::format("E:{}", refused));
            return;
        }

        if (item)
            CharacterDatabase.Execute("REPLACE INTO mod_trading_post_frozen (account, item, month) VALUES ({}, {}, {})", account, item, month);
        else
            CharacterDatabase.Execute("DELETE FROM mod_trading_post_frozen WHERE account = {}", account);
        Send(player, fmt::format("F:{}", item));
    }

    // Writes what the counters did since the last time. World thread.
    void FlushProgress()
    {
        std::vector<std::tuple<uint32, uint32, uint32>> rows;
        uint32 month;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            month = currentMonth;
            for (auto const& [account, activity] : dirtyProgress)
            {
                auto itr = accounts.find(account);
                if (itr == accounts.end())
                    continue;
                auto progress = itr->second.progress.find(activity);
                if (progress != itr->second.progress.end())
                    rows.emplace_back(account, activity, progress->second);
            }
            dirtyProgress.clear();
        }
        if (rows.empty())
            return;

        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        for (auto const& [account, activity, progress] : rows)
            trans->Append("INSERT INTO mod_trading_post_progress (account, month, activity, progress) VALUES ({}, {}, {}, {}) "
                "ON DUPLICATE KEY UPDATE progress = GREATEST(progress, VALUES(progress))", account, month, activity, progress);
        CharacterDatabase.CommitTransaction(trans);
    }

    // The milestones past what's been paid that these points reach, as one reward: false if there are
    // none. Caller holds stateLock.
    bool DueReward(uint32 paidPoints, uint32 points, uint32 month, PendingReward& reward)
    {
        for (Milestone const& milestone : settings.milestones)
            if (milestone.points > paidPoints && milestone.points <= points)
            {
                reward.tender += milestone.tender;
                reward.paidPoints = milestone.points;
            }
        // The milestones were lowered past what's been paid: no more Tender, but the log is complete.
        uint32 const lastPoints = settings.milestones.back().points;
        if (!reward.paidPoints && paidPoints >= lastPoints && points >= lastPoints)
            reward.paidPoints = paidPoints;
        if (!reward.paidPoints)
            return false;

        reward.month = month;
        reward.last = reward.paidPoints >= lastPoints;
        reward.bonus = reward.last ? themes[month % 100].bonusItem : 0;
        return true;
    }

    // The same for an account's current month, marked as queued. Caller holds stateLock.
    bool TakeDueReward(AccountMonth& state, uint32 account, uint32 month, PendingReward& reward)
    {
        if (state.logPaid || !DueReward(state.paidPoints, state.points, month, reward))
            return false;

        reward.account = account;
        state.paidPoints = reward.paidPoints;
        state.logPaid = reward.last;
        return true;
    }

    // Pays the log's rewards that came due. World thread.
    void PayRewards()
    {
        std::vector<PendingReward> rewards;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            rewards.swap(pendingRewards);
        }

        std::vector<PendingReward> held;
        for (PendingReward const& reward : rewards)
        {
            // One at a time for an account. The month's row only remembers the highest milestone
            // paid, so a later one written past a failed write would hide it from the next startup.
            if (!rewardsInFlight.insert(reward.account).second)
            {
                held.push_back(reward);
                continue;
            }

            uint32 const bonus = reward.bonus;

            ItemInfo info;
            bool giveBonus = false;
            {
                std::lock_guard<std::mutex> guard(stateLock);
                auto known = itemInfo.find(bonus);
                if (known != itemInfo.end() && !purchases[reward.account].count(bonus))
                {
                    info = known->second;
                    giveBonus = true;
                    purchases[reward.account].insert(bonus);
                }
            }

            CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
            // Spendable once it's written, so nothing can be spent that a failed write takes back.
            Record(trans, reward.account, reward.guid, reward.tender, Balance(reward.account) + reward.tender, "log", 0);
            // In either order: a reward that failed comes back after later ones.
            trans->Append("INSERT INTO mod_trading_post_month (account, month, log_paid, log_points) VALUES ({}, {}, {}, {}) "
                "ON DUPLICATE KEY UPDATE log_paid = GREATEST(log_paid, VALUES(log_paid)), log_points = GREATEST(log_points, VALUES(log_points))",
                reward.account, reward.month, reward.last ? 1 : 0, reward.paidPoints);
            bool const shared = giveBonus && SharedWithAccount(info);
            if (giveBonus)
                RecordPurchase(trans, reward.account, reward.guid, bonus, info, 0, shared);

            commits.AddCallback(CharacterDatabase.AsyncCommitTransaction(trans)).AfterComplete(
                [reward, info, giveBonus, shared](bool success)
                {
                    uint32 const account = reward.account;
                    uint32 const bonus = reward.bonus;
                    if (!success)
                    {
                        if (giveBonus)
                        {
                            std::lock_guard<std::mutex> guard(stateLock);
                            purchases[account].erase(bonus);
                        }
                        // The month's flag stays up: this try again is the only one due.
                        failedRewards.push_back(reward);
                        LOG_ERROR("module", "mod-trading-post: the Traveler's Log reward of account {} could not be saved; will try again", account);
                        return;
                    }

                    rewardsInFlight.erase(account);
                    Pay(account, reward.tender);
                    if (giveBonus)
                    {
                        if (shared)
                            TeachOnline(account, info);
                        else
                            MailPurchase(account, reward.guid, bonus, info);
                    }
                    if (Player* player = AccountPlayer(account))
                    {
                        ChatHandler chat(player->GetSession());
                        if (reward.last)
                            chat.PSendSysMessage("Traveler's Log complete! You earned {} Trader's Tender.", reward.tender);
                        else
                            chat.PSendSysMessage("Traveler's Log: {} points reached! You earned {} Trader's Tender.", reward.paidPoints, reward.tender);
                        if (giveBonus)
                            chat.PSendSysMessage(shared
                                ? "This month's reward, the {}, is yours on every character of your account."
                                : "This month's reward, the {}, is in your mailbox.", info.name);
                        SendState(player);
                        TradingPost::SendCurrency(player);
                    }
                });
        }

        // Ahead of anything that came in meanwhile, which is for higher milestones.
        if (!held.empty())
        {
            std::lock_guard<std::mutex> guard(stateLock);
            pendingRewards.insert(pendingRewards.begin(), held.begin(), held.end());
        }
    }

    // One account's month from its rows. Caller holds stateLock.
    void AddLoadedProgress(uint32 account, uint32 activity, uint32 progress)
    {
        AccountMonth& state = accounts[account];
        state.progress[activity] = progress;
        auto itr = std::find_if(monthActivities.begin(), monthActivities.end(), [activity](Activity const& a) { return a.id == activity; });
        if (itr != monthActivities.end() && progress >= itr->amount)
            state.points += itr->points;
    }

    // This month's list and what accounts have done of it. World thread. A reload keeps what's in
    // memory, as the database can be behind it: writes are queued. Only the points are worked out
    // again, as the activities may have changed.
    void LoadMonth(time_t when, bool keepAccounts)
    {
        uint32 const month = MonthOf(when);
        uint8 const theme = uint8(month % 100);

        std::vector<Activity> activities;
        if (QueryResult result = WorldDatabase.Query("SELECT id, type, target, amount, points, sort, name, description "
            "FROM mod_trading_post_activity WHERE theme IN (0, {}) ORDER BY sort, id", theme))
        {
            do
            {
                Field* fields = result->Fetch();
                Activity activity;
                activity.id = fields[0].Get<uint32>();
                activity.type = fields[1].Get<uint8>();
                activity.target = fields[2].Get<uint32>();
                activity.amount = fields[3].Get<uint32>();
                activity.points = fields[4].Get<uint32>();
                activity.sort = fields[5].Get<uint16>();
                activity.name = fields[6].Get<std::string>();
                activity.description = fields[7].Get<std::string>();
                if (!activity.type || activity.type >= MAX_ACTIVITY_TYPE || !activity.amount)
                {
                    LOG_ERROR("server.loading", "mod-trading-post: activity {} has an unknown type or no amount; left out", activity.id);
                    continue;
                }
                activities.push_back(std::move(activity));
            } while (result->NextRow());
        }

        QueryResult progress, claims;
        if (!keepAccounts)
        {
            progress = CharacterDatabase.Query("SELECT account, activity, progress FROM mod_trading_post_progress WHERE month = {}", month);
            claims = CharacterDatabase.Query("SELECT account, cache_taken, log_paid, log_points FROM mod_trading_post_month WHERE month = {}", month);
        }

        std::vector<PendingReward> uncollected;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            currentMonth = month;
            currentTheme = theme;
            monthActivities = std::move(activities);
            for (auto& list : activitiesByType)
                list.clear();
            for (Activity const& activity : monthActivities)
                activitiesByType[activity.type].push_back(&activity);

            if (keepAccounts)
            {
                for (auto& [account, state] : accounts)
                {
                    state.points = 0;
                    for (Activity const& activity : monthActivities)
                        if (auto itr = state.progress.find(activity.id); itr != state.progress.end() && itr->second >= activity.amount)
                            state.points += activity.points;
                }
            }
            else
            {
                accounts.clear();
                dirtyProgress.clear();
            }

            if (progress)
                do
                {
                    Field* fields = progress->Fetch();
                    AddLoadedProgress(fields[0].Get<uint32>(), fields[1].Get<uint32>(), fields[2].Get<uint32>());
                } while (progress->NextRow());
            if (claims)
                do
                {
                    Field* fields = claims->Fetch();
                    AccountMonth& state = accounts[fields[0].Get<uint32>()];
                    state.cacheTaken = fields[1].Get<uint8>() != 0;
                    state.logPaid = fields[2].Get<uint8>() != 0;
                    state.paidPoints = fields[3].Get<uint32>();
                } while (claims->NextRow());

            // Reached, and the server stopped before it paid; or the milestones changed.
            for (auto& [account, state] : accounts)
            {
                PendingReward reward;
                if (TakeDueReward(state, account, month, reward))
                    uncollected.push_back(reward);
            }
        }

        for (PendingReward& reward : uncollected)
        {
            if (QueryResult result = CharacterDatabase.Query("SELECT guid FROM characters WHERE account = {} AND " SQL_NOT_HOME_VIEWER " ORDER BY logout_time DESC LIMIT 1", reward.account))
                reward.guid = result->Fetch()[0].Get<uint32>();
            std::lock_guard<std::mutex> guard(stateLock);
            pendingRewards.push_back(reward);
        }

    }

    // Startup only, when no write is still on its way: a month that ended with a reward unpaid,
    // because the write failed or the server stopped first. A month's progress is no use after
    // that, so it goes; the claims stay as history.
    void RecoverPastRewards(uint32 month)
    {
        struct PastActivity { uint8 theme; uint32 amount; uint32 points; };
        std::unordered_map<uint32, PastActivity> activities;
        if (QueryResult result = WorldDatabase.Query("SELECT id, theme, amount, points FROM mod_trading_post_activity"))
            do
            {
                Field* fields = result->Fetch();
                activities[fields[0].Get<uint32>()] = { fields[1].Get<uint8>(), fields[2].Get<uint32>(), fields[3].Get<uint32>() };
            } while (result->NextRow());

        std::map<std::pair<uint32, uint32>, uint32> earned;     // account, month -> points
        if (QueryResult result = CharacterDatabase.Query("SELECT account, month, activity, progress FROM mod_trading_post_progress WHERE month < {}", month))
            do
            {
                Field* fields = result->Fetch();
                uint32 const pastMonth = fields[1].Get<uint32>();
                auto activity = activities.find(fields[2].Get<uint32>());
                if (activity != activities.end() && (!activity->second.theme || activity->second.theme == pastMonth % 100)
                    && fields[3].Get<uint32>() >= activity->second.amount)
                    earned[{ fields[0].Get<uint32>(), pastMonth }] += activity->second.points;
            } while (result->NextRow());

        std::map<std::pair<uint32, uint32>, uint32> paid;       // account, month -> last milestone paid
        std::set<std::pair<uint32, uint32>> finished;
        if (QueryResult result = CharacterDatabase.Query("SELECT account, month, log_paid, log_points FROM mod_trading_post_month WHERE month < {}", month))
            do
            {
                Field* fields = result->Fetch();
                std::pair<uint32, uint32> const key(fields[0].Get<uint32>(), fields[1].Get<uint32>());
                paid[key] = fields[3].Get<uint32>();
                if (fields[2].Get<uint8>())
                    finished.insert(key);
            } while (result->NextRow());

        for (auto const& [key, points] : earned)
        {
            if (finished.count(key))
                continue;

            PendingReward reward;
            reward.account = key.first;
            auto const before = paid.find(key);
            {
                std::lock_guard<std::mutex> guard(stateLock);
                if (!DueReward(before != paid.end() ? before->second : 0, points, key.second, reward))
                    continue;
            }

            if (QueryResult result = CharacterDatabase.Query("SELECT guid FROM characters WHERE account = {} AND " SQL_NOT_HOME_VIEWER " ORDER BY logout_time DESC LIMIT 1", key.first))
                reward.guid = result->Fetch()[0].Get<uint32>();

            LOG_INFO("server.loading", "mod-trading-post: paying account {} the Traveler's Log reward of month {}", key.first, key.second);
            std::lock_guard<std::mutex> guard(stateLock);
            pendingRewards.push_back(reward);
        }

        CharacterDatabase.Execute("DELETE FROM mod_trading_post_progress WHERE month < {}", month);
    }

    bool FindAccountTable(uint8 kind)
    {
        // In a LIKE pattern an underscore matches any one character: escaped, so only the table
        // itself counts.
        std::string pattern;
        for (char c : std::string_view(ACCOUNT_TABLES[kind]))
            pattern += c == '_' ? "\\_" : std::string(1, c);
        return CharacterDatabase.Query("SHOW TABLES LIKE '{}'", pattern) != nullptr;
    }

    // The spell an item teaches and the creature that spell shows, for the addon's preview.
    bool ReadItem(uint32 entry, ItemInfo& info)
    {
        ItemTemplate const* proto = sObjectMgr->GetItemTemplate(entry);
        if (!proto)
            return false;

        info.name = proto->Name1;
        for (auto const& spell : proto->Spells)
            if (spell.SpellTrigger == ITEM_SPELLTRIGGER_LEARN_SPELL_ID && spell.SpellId > 0)
                info.teaches = uint32(spell.SpellId);

        if (!info.teaches)
            return true;

        SkillLineAbilityMapBounds bounds = sSpellMgr->GetSkillLineAbilityMapBounds(info.teaches);
        for (auto itr = bounds.first; itr != bounds.second; ++itr)
        {
            if (itr->second->SkillLine == SKILL_MOUNTS)
                info.kind = KIND_MOUNT;
            else if (itr->second->SkillLine == SKILL_COMPANIONS)
                info.kind = KIND_PET;
        }

        if (SpellInfo const* spell = sSpellMgr->GetSpellInfo(info.teaches))
            for (uint8 i = 0; i < MAX_SPELL_EFFECTS; ++i)
            {
                if (spell->Effects[i].ApplyAuraName == SPELL_AURA_MOUNTED || spell->Effects[i].Effect == SPELL_EFFECT_SUMMON)
                {
                    info.creature = uint32(std::max(spell->Effects[i].MiscValue, 0));
                    if (info.creature)
                        break;
                }
            }
        return true;
    }
}

bool TradingPost::IsRealPlayer(Player* player)
{
    WorldSession* session = player ? player->GetSession() : nullptr;
    return session && !IsBotSession(session) && !IsHomeViewer(player);
}

bool TradingPost::Enabled()
{
    return settings.enabled;
}

uint32 TradingPost::Balance(uint32 account)
{
    std::lock_guard<std::mutex> guard(stateLock);
    auto itr = balances.find(account);
    return itr != balances.end() ? itr->second : 0;
}

void TradingPost::Adjust(uint32 account, int64 amount)
{
    uint32 balance;
    {
        std::lock_guard<std::mutex> guard(stateLock);
        uint32& tender = balances[account];
        amount = std::clamp<int64>(amount, -int64(tender), int64(MAX_TENDER) - tender);
        tender = uint32(int64(tender) + amount);
        balance = tender;
    }
    if (!amount)
        return;

    CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
    Record(trans, account, 0, amount, balance, "gm", 0);
    CharacterDatabase.CommitTransaction(trans);
    if (Player* player = AccountPlayer(account))
    {
        SendState(player);
        SendCurrency(player);
    }
}

void TradingPost::SendCurrency(Player* player)
{
    if (!settings.enabled || !settings.currencyItem || !IsRealPlayer(player))
        return;

    std::string const message = fmt::format("{}\tS:{}:{}:{}:{}", CURRENCY_PREFIX, settings.currencyItem,
        Balance(player->GetSession()->GetAccountId()), CURRENCY_SECTION, CURRENCY_NAME);
    WorldPacket data;
    ChatHandler::BuildChatPacket(data, CHAT_MSG_WHISPER, LANG_ADDON, player, player, message);
    player->GetSession()->SendPacket(&data);
}

void TradingPost::LoadConfig()
{
    settings.enabled = sConfigMgr->GetOption<bool>("TradingPost.Enable", true);
    settings.cacheTender = sConfigMgr->GetOption<uint32>("TradingPost.Cache.Tender", 500);
    std::string const milestoneText = sConfigMgr->GetOption<std::string>("TradingPost.Log.Milestones", DEFAULT_MILESTONES);
    std::vector<Milestone> milestones = ParseMilestones(milestoneText);
    if (milestones.empty())
    {
        LOG_ERROR("server.loading", "mod-trading-post: TradingPost.Log.Milestones '{}' can't be read; using '{}'", milestoneText, DEFAULT_MILESTONES);
        milestones = ParseMilestones(DEFAULT_MILESTONES);
    }
    uint32 tender = 0;
    for (Milestone const& milestone : milestones)
        tender += milestone.tender;
    settings.logTender = tender;
    settings.logPoints = milestones.back().points;
    {
        std::lock_guard<std::mutex> guard(stateLock);
        settings.milestones = std::move(milestones);
    }
    settings.flushMs = std::max<uint32>(sConfigMgr->GetOption<uint32>("TradingPost.Log.SaveSeconds", 30), 5) * IN_MILLISECONDS;
    settings.accountWide = sConfigMgr->GetOption<bool>("TradingPost.AccountWideSpells", true);
    settings.progressionGate = sConfigMgr->GetOption<bool>("TradingPost.ProgressionGate", true);
    // mod-individual-progression's own: no phase past it, 0 = none
    settings.progressionLimit = sConfigMgr->GetOption<uint32>("IndividualProgression.ProgressionLimit", 0);
    settings.currencyItem = sConfigMgr->GetOption<uint32>("TradingPost.CurrencyItem", 37711);
}

static void LoadData(bool withAccounts)
{
    Theme loadedThemes[MAX_THEME + 1];
    std::vector<Goods> loadedStock[MAX_THEME + 1];
    std::unordered_map<uint32, ItemInfo> loadedItems;
    std::unordered_set<uint32> creatures;
    uint32 skipped = 0, goodsCount = 0;

    auto know = [&](uint32 item) -> bool
    {
        if (loadedItems.count(item))
            return true;
        ItemInfo info;
        if (!ReadItem(item, info))
            return false;
        if (info.creature)
            creatures.insert(info.creature);
        loadedItems.emplace(item, std::move(info));
        return true;
    };

    if (QueryResult result = WorldDatabase.Query("SELECT theme, name, description, bonus_item FROM mod_trading_post_theme"))
    {
        do
        {
            Field* fields = result->Fetch();
            uint8 const theme = fields[0].Get<uint8>();
            if (!theme || theme > MAX_THEME)
                continue;
            loadedThemes[theme].name = fields[1].Get<std::string>();
            loadedThemes[theme].description = fields[2].Get<std::string>();
            uint32 const bonus = fields[3].Get<uint32>();
            // The item library may not be on this server.
            if (bonus && know(bonus))
                loadedThemes[theme].bonusItem = bonus;
        } while (result->NextRow());
    }

    if (QueryResult result = WorldDatabase.Query("SELECT theme, item, price, phase, sort FROM mod_trading_post_stock ORDER BY theme, sort, item"))
    {
        do
        {
            Field* fields = result->Fetch();
            uint8 const theme = fields[0].Get<uint8>();
            uint32 const item = fields[1].Get<uint32>();
            if (!theme || theme > MAX_THEME || !know(item))
            {
                ++skipped;
                continue;
            }
            Goods good;
            good.item = item;
            good.price = fields[2].Get<uint32>();
            good.phase = std::min<uint8>(fields[3].Get<uint8>(), PROGRESSION_LAST_PHASE);
            good.sort = fields[4].Get<uint16>();
            loadedStock[theme].push_back(good);
            ++goodsCount;
        } while (result->NextRow());
    }

    for (uint8 kind = KIND_MOUNT; kind <= KIND_PET; ++kind)
        accountTables[kind] = FindAccountTable(kind);
    progressionQuests = sObjectMgr->GetQuestTemplate(PROGRESSION_QUEST + 1) != nullptr;

    std::unordered_map<uint32, uint32> loadedBalances;
    std::unordered_map<uint32, std::unordered_set<uint32>> loadedPurchases;
    std::unordered_map<uint32, uint32> loadedFrozen;
    if (withAccounts)
    {
        // A balance below 0 can only be the leftover of a change that failed. The server counts it
        // as 0, so the row has to say 0 too, or every change after it would be off by as much.
        CharacterDatabase.DirectExecute("UPDATE mod_trading_post_wallet SET tender = 0 WHERE tender < 0");

        if (QueryResult result = CharacterDatabase.Query("SELECT account, tender FROM mod_trading_post_wallet WHERE tender > 0"))
            do
            {
                Field* fields = result->Fetch();
                loadedBalances[fields[0].Get<uint32>()] = uint32(fields[1].Get<int32>());
            } while (result->NextRow());

        if (QueryResult result = CharacterDatabase.Query("SELECT account, item FROM mod_trading_post_purchase"))
            do
            {
                Field* fields = result->Fetch();
                loadedPurchases[fields[0].Get<uint32>()].insert(fields[1].Get<uint32>());
            } while (result->NextRow());

        if (QueryResult result = CharacterDatabase.Query("SELECT account, item FROM mod_trading_post_frozen"))
            do
            {
                Field* fields = result->Fetch();
                loadedFrozen[fields[0].Get<uint32>()] = fields[1].Get<uint32>();
            } while (result->NextRow());
    }

    {
        std::lock_guard<std::mutex> guard(stateLock);
        for (uint8 theme = 0; theme <= MAX_THEME; ++theme)
        {
            themes[theme] = std::move(loadedThemes[theme]);
            stock[theme] = std::move(loadedStock[theme]);
        }
        itemInfo = std::move(loadedItems);
        previewCreatures = std::move(creatures);
        if (withAccounts)
        {
            balances = std::move(loadedBalances);
            purchases = std::move(loadedPurchases);
            frozen = std::move(loadedFrozen);
        }
    }

    // Paid for, and the server stopped before the mail went.
    if (withAccounts)
        if (QueryResult result = CharacterDatabase.Query("SELECT account, guid, item FROM mod_trading_post_purchase WHERE delivered = 0"))
            do
            {
                Field* fields = result->Fetch();
                uint32 const item = fields[2].Get<uint32>();
                // It may have left the shelves since it was paid for.
                ItemInfo info;
                if (ReadItem(item, info))
                    MailPurchase(fields[0].Get<uint32>(), fields[1].Get<uint32>(), item, info);
                else
                    LOG_ERROR("server.loading", "mod-trading-post: account {} paid for item {}, which no longer exists", fields[0].Get<uint32>(), item);
            } while (result->NextRow());

    time_t const now = GameTime::GetGameTime().count();
    if (withAccounts)
        RecoverPastRewards(MonthOf(now));
    LoadMonth(now, !withAccounts && MonthOf(now) == currentMonth);
    LOG_INFO("server.loading", "mod-trading-post: month {} '{}', {} activities, {} goods ({} skipped), {} wallet(s)",
        currentMonth, themes[currentTheme].name, monthActivities.size(), goodsCount, skipped, balances.size());
}

void TradingPost::LoadAll()
{
    LoadData(true);
}

void TradingPost::ReloadWorldData()
{
    LoadData(false);
}

// The sharing modules forget an account's spells when its last character is deleted. What it paid
// for here stays its own: the next character gets it back.
void TradingPost::RestorePurchases(Player* player)
{
    if (!settings.enabled || !settings.accountWide || !IsRealPlayer(player))
        return;

    uint32 const account = player->GetSession()->GetAccountId();
    std::vector<std::pair<uint32, ItemInfo>> shared;
    {
        std::lock_guard<std::mutex> guard(stateLock);
        auto bought = purchases.find(account);
        if (bought == purchases.end())
            return;
        for (uint32 item : bought->second)
            if (auto info = itemInfo.find(item); info != itemInfo.end() && SharedWithAccount(info->second))
                shared.emplace_back(item, info->second);
    }
    if (shared.empty())
        return;

    std::unordered_set<uint32> const spells = AccountSpells(account);
    bool const selfFound = IsSelfFound(player->GetGUID().GetCounter());
    for (auto const& [item, info] : shared)
    {
        if (spells.count(info.teaches))
            continue;
        CharacterDatabase.Execute("INSERT IGNORE INTO {} (account_id, spell) VALUES ({}, {})", ACCOUNT_TABLES[info.kind], account, info.teaches);
        if (!selfFound && !player->HasSpell(info.teaches))
            player->learnSpell(info.teaches);
    }
}

void TradingPost::Progress(Player* player, ActivityType type, uint32 target, uint32 amount)
{
    if (!settings.enabled || !amount || !IsRealPlayer(player))
        return;

    uint32 const account = player->GetSession()->GetAccountId();
    uint32 const guid = player->GetGUID().GetCounter();

    // Tender belongs to the account, and a Self-Found character plays apart from it.
    if (IsSelfFound(guid))
        return;

    struct Moved { uint32 id; uint32 progress; bool done; uint32 points; std::string name; };
    std::vector<Moved> moved;
    uint32 total = 0;
    bool wantsAddon = false;
    {
        std::lock_guard<std::mutex> guard(stateLock);
        auto const& list = activitiesByType[type];
        if (list.empty())
            return;

        AccountMonth* state = nullptr;
        for (Activity const* activity : list)
        {
            if (activity->target && activity->target != target)
                continue;

            if (!state)
                state = &accounts[account];
            uint32& progress = state->progress[activity->id];
            if (progress >= activity->amount)
                continue;

            progress = uint32(std::min<uint64>(uint64(progress) + amount, activity->amount));
            bool const done = progress >= activity->amount;
            dirtyProgress.emplace(account, activity->id);
            if (done)
                state->points += activity->points;
            moved.push_back({ activity->id, progress, done, activity->points, activity->name });
        }

        if (state)
        {
            total = state->points;
            PendingReward reward;
            reward.guid = guid;
            if (TakeDueReward(*state, account, currentMonth, reward))
                pendingRewards.push_back(reward);
        }
        wantsAddon = addonPlayers.count(guid) != 0;
    }

    for (Moved const& step : moved)
    {
        if (wantsAddon)
            Send(player, fmt::format("P:{}:{}:{}", step.id, step.progress, total));
        if (step.done)
            ChatHandler(player->GetSession()).PSendSysMessage("Traveler's Log: {} complete ({} points, {}/{}).",
                step.name, step.points, total, settings.logPoints);
    }
}

void TradingPost::Update(uint32 diff)
{
    commits.ProcessReadyCallbacks();
    if (!settings.enabled)
        return;

    PayRewards();

    flushTimer += diff;
    if (flushTimer >= settings.flushMs)
    {
        flushTimer = 0;
        FlushProgress();

        if (!failedRewards.empty())
        {
            for (PendingReward const& reward : failedRewards)
                rewardsInFlight.erase(reward.account);
            std::lock_guard<std::mutex> guard(stateLock);
            pendingRewards.insert(pendingRewards.begin(), failedRewards.begin(), failedRewards.end());
            failedRewards.clear();
        }

        std::vector<FailedMail> mails;
        mails.swap(failedMails);
        for (FailedMail const& mail : mails)
            MailPurchase(mail.account, mail.guid, mail.item, mail.info);
    }

    monthTimer += diff;
    if (monthTimer < MONTH_CHECK_MS)
        return;
    monthTimer = 0;

    time_t const now = GameTime::GetGameTime().count();
    if (MonthOf(now) == currentMonth)
        return;

    FlushProgress();
    LoadMonth(now, false);
    LOG_INFO("module", "mod-trading-post: month {} begins: {}", currentMonth, themes[currentTheme].name);

    std::vector<uint32> online;
    {
        std::lock_guard<std::mutex> guard(stateLock);
        online.assign(addonPlayers.begin(), addonPlayers.end());
    }
    for (uint32 guid : online)
        if (Player* player = ObjectAccessor::FindConnectedPlayer(ObjectGuid::Create<HighGuid::Player>(guid)))
            Send(player, "M");
}

void TradingPost::SaveProgress()
{
    FlushProgress();
}

void TradingPost::Forget(Player* player)
{
    uint32 const guid = player->GetGUID().GetCounter();
    std::lock_guard<std::mutex> guard(stateLock);
    addonPlayers.erase(guid);
    shopNpc.erase(guid);
    costlyRequests.erase(guid);
}

bool TradingPost::OpenShop(Player* player, Creature* creature)
{
    if (!settings.enabled)
        return false;

    uint32 const guid = player->GetGUID().GetCounter();
    {
        std::lock_guard<std::mutex> guard(stateLock);
        if (!addonPlayers.count(guid))
            return false;
        shopNpc[guid] = creature->GetGUID();
    }
    Send(player, "OPEN");
    return true;
}

void TradingPost::Dispatch(Player* player, std::string_view payload)
{
    std::size_t const colon = payload.find(':');
    std::string_view const command = payload.substr(0, colon);
    std::string_view const argument = colon == std::string_view::npos ? std::string_view() : payload.substr(colon + 1);

    uint32 number = 0;
    bool const hasNumber = ParseUInt(argument, number);

    if (command == "HELLO")
    {
        {
            std::lock_guard<std::mutex> guard(stateLock);
            addonPlayers.insert(player->GetGUID().GetCounter());
        }
        Send(player, fmt::format("H:{}", PROTOCOL));
        SendState(player);
    }
    else if (command == "STATE")
        SendState(player);
    else if (command == "LOG")
        SendLog(player);
    else if (command == "R" && hasNumber)
    {
        // Lets a model draw that the client has never met. The client's own way of asking is
        // closed to an addon; only creatures the module shows can be asked for.
        bool known;
        {
            std::lock_guard<std::mutex> guard(stateLock);
            known = previewCreatures.count(number) != 0;
        }
        if (known)
        {
            WorldPacket query(CMSG_CREATURE_QUERY, 12);
            query << number << uint64(0);
            player->GetSession()->HandleCreatureQueryOpcode(query);
        }
    }
    else if (command != "STOCK" && command != "CACHE" && command != "BUY" && command != "FREEZE")
        return;
    else if (!AtShop(player))
        Send(player, "E:You need to be at the Trading Post for that.");
    else if (TooSoon(player))
    {
        // These read the database on the world thread; only a modified client sends this many.
        if (command == "BUY" && hasNumber)
            Send(player, fmt::format("B:{}:0", number));
    }
    else if (command == "STOCK")
        SendStock(player);
    else if (command == "CACHE")
        ClaimCache(player);
    else if (command == "BUY" && hasNumber)
        Buy(player, number);
    else if (command == "FREEZE" && hasNumber)
        Freeze(player, number);
}
