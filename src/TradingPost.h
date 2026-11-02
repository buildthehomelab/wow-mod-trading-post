/*
 * mod-trading-post: retail's Trading Post and Traveler's Log.
 *
 * Every calendar month brings a theme with its own stock and its own list of activities. Activities
 * earn points for the whole account; 1,000 points pay Trader's Tender and the month's bonus reward.
 * The Collector's Cache pays Tender once a month to whoever visits. A proprietor in each capital
 * sells the stock for Tender, and one item an account freezes stays on sale for it in later months.
 *
 * Released under the MIT License.
 */

#ifndef MOD_TRADING_POST_H
#define MOD_TRADING_POST_H

#include "Define.h"

#include <string>
#include <string_view>
#include <type_traits>
#include <utility>

class Player;
class Creature;

namespace TradingPost
{
    constexpr char const* PREFIX = "TPOST";
    constexpr uint32 PROTOCOL = 1;
    constexpr uint32 MAX_THEME = 12;

    // The types in mod_trading_post_activity; tools/build_data.py writes the same numbers.
    enum ActivityType : uint8
    {
        ACTIVITY_KILL = 1,          // target: creature type, 0 any
        ACTIVITY_KILL_ELITE,
        ACTIVITY_KILL_RARE,
        ACTIVITY_QUEST,
        ACTIVITY_DUNGEON_BOSS,
        ACTIVITY_RAID_BOSS,
        ACTIVITY_GATHER,            // target: skill, 0 any
        ACTIVITY_FISH,
        ACTIVITY_CRAFT,
        ACTIVITY_BG_PLAY,
        ACTIVITY_BG_WIN,
        ACTIVITY_LEVEL,
        ACTIVITY_ACHIEVEMENT,
        ACTIVITY_PVP_KILL,
        MAX_ACTIVITY_TYPE,
    };

    // bots have no account of their own to reward
    template <typename Session, typename = void>
    struct HasIsHeadless : std::false_type { };
    template <typename Session>
    struct HasIsHeadless<Session, std::void_t<decltype(std::declval<Session&>().IsHeadless())>> : std::true_type { };
    template <typename Session, typename = void>
    struct HasIsBot : std::false_type { };
    template <typename Session>
    struct HasIsBot<Session, std::void_t<decltype(std::declval<Session&>().IsBot())>> : std::true_type { };

    template <typename Session>
    bool IsBotSession(Session* session)
    {
        if constexpr (HasIsHeadless<Session>::value)
            return session->IsHeadless();
        else if constexpr (HasIsBot<Session>::value)
            return session->IsBot();
        else
            return false;
    }

    bool IsRealPlayer(Player* player);

    // Config; world data and account state at startup; world data alone for `.tradingpost reload`,
    // as account writes may still be on their way to the database.
    void LoadConfig();
    void LoadAll();
    void ReloadWorldData();

    // At login: gives back what the account bought and the sharing modules forgot.
    void RestorePurchases(Player* player);

    // One step of an activity, for this player's account. Any thread.
    void Progress(Player* player, ActivityType type, uint32 target = 0, uint32 amount = 1);

    // World thread: month change, pays what is waiting, writes progress.
    void Update(uint32 diff);
    void SaveProgress();

    // What the addon asks for; the world thread (CMSG_MESSAGECHAT is thread-unsafe).
    void Dispatch(Player* player, std::string_view payload);

    // Talking to a proprietor. False when the player has no addon to show the shop in.
    bool OpenShop(Player* player, Creature* creature);
    void Forget(Player* player);

    bool Enabled();
    uint32 Balance(uint32 account);

    // The balance's row in DragonUI's Currency tab.
    constexpr char const* DRAGONUI_CURRENCY_PREFIX = "DUI_CURRENCY";
    void SendCurrency(Player* player);
    void Adjust(uint32 account, int64 amount);
}

#endif
