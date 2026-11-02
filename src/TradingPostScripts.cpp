/*
 * mod-trading-post: what the game tells the Traveler's Log, the proprietors and the commands.
 *
 * Released under the MIT License.
 */

#include "TradingPost.h"

#include "AllBattlegroundScript.h"
#include "Battleground.h"
#include "Chat.h"
#include "ChatCommand.h"
#include "Creature.h"
#include "DBCStores.h"
#include "GameObject.h"
#include "GossipDef.h"
#include "Group.h"
#include "InstanceScript.h"
#include "Item.h"
#include "Map.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "ScriptedGossip.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "WorldSession.h"

using namespace TradingPost;
using namespace Acore::ChatCommands;

namespace
{
    // mod-individual-progression rewards hidden quests by itself: phases, PvP ranks, its Naxxramas
    // entrance flag. Nobody turned those in.
    constexpr uint32 HIDDEN_QUEST_FIRST = 66000;
    constexpr uint32 HIDDEN_QUEST_LAST = 66114;
    constexpr uint32 HIDDEN_QUEST_NAXX_FLAG = 9378;

    void CountKill(Player* player, Creature* killed)
    {
        CreatureTemplate const* info = killed->GetCreatureTemplate();
        uint32 const rank = info->rank;
        if (rank == CREATURE_ELITE_RARE || rank == CREATURE_ELITE_RAREELITE)
            Progress(player, ACTIVITY_KILL_RARE);

        // Nothing for what's far below the player: that would be a farm.
        if (!player->isHonorOrXPTarget(killed))
            return;

        Progress(player, ACTIVITY_KILL, info->type);
        if (killed->isElite())
            Progress(player, ACTIVITY_KILL_ELITE);
    }
}

class TradingPostPlayerScript : public PlayerScript
{
public:
    TradingPostPlayerScript() : PlayerScript("TradingPostPlayerScript",
        {
            PLAYERHOOK_CAN_PLAYER_USE_PRIVATE_CHAT,
            PLAYERHOOK_ON_LOGIN,
            PLAYERHOOK_ON_LOGOUT,
            PLAYERHOOK_ON_CREATURE_KILL_CREDIT,
            PLAYERHOOK_ON_PLAYER_COMPLETE_QUEST,
            PLAYERHOOK_ON_LEVEL_CHANGED,
            PLAYERHOOK_ON_ACHI_COMPLETE,
            PLAYERHOOK_ON_UPDATE_GATHERING_SKILL,
            PLAYERHOOK_ON_UPDATE_FISHING_SKILL,
            PLAYERHOOK_ON_UPDATE_CRAFTING_SKILL,
            PLAYERHOOK_ON_VICTIM_REWARD_AFTER,
        }) { }

    // The addon whispers itself; those messages never show up as chat.
    bool OnPlayerCanUseChat(Player* player, uint32 /*type*/, uint32 lang, std::string& msg, Player* receiver) override
    {
        if (lang != LANG_ADDON || !receiver || receiver != player)
            return true;

        // DragonUI asks for its currencies by whispering itself. It's let through, so that any other
        // module listing one gets to answer too.
        if (msg == std::string(DRAGONUI_CURRENCY_PREFIX) + "\tHELLO")
        {
            SendCurrency(player);
            return true;
        }

        std::string const prefixTab = std::string(PREFIX) + "\t";
        if (msg.compare(0, prefixTab.size(), prefixTab) != 0)
            return true;

        if (Enabled() && IsRealPlayer(player))
            Dispatch(player, std::string_view(msg).substr(prefixTab.size()));
        return false;
    }

    void OnPlayerLogin(Player* player) override
    {
        RestorePurchases(player);
    }

    void OnPlayerLogout(Player* player) override
    {
        Forget(player);
    }

    // The killer's credit, shared with the group the way experience is. Pets count for the owner.
    void OnPlayerCreatureKillCredit(Player* player, Creature* killed) override
    {
        if (!Enabled() || !killed || killed->IsPet() || killed->IsTotem() || killed->GetCreatureType() == CREATURE_TYPE_CRITTER)
            return;

        // The hook also fires when the core gives no reward: guards did most of the work.
        if (!killed->IsDamageEnoughForLootingAndReward() || killed->IsLootRewardDisabled())
            return;

        Group* group = player->GetGroup();
        if (!group)
        {
            CountKill(player, killed);
            return;
        }

        for (GroupReference* itr = group->GetFirstMember(); itr; itr = itr->next())
        {
            Player* member = itr->GetSource();
            if (member && member->IsInMap(player) && member->IsAtGroupRewardDistance(killed))
                CountKill(member, killed);
        }
    }

    void OnPlayerCompleteQuest(Player* player, Quest const* quest) override
    {
        if (!quest || quest->GetQuestId() == HIDDEN_QUEST_NAXX_FLAG)
            return;
        if (quest->GetQuestId() < HIDDEN_QUEST_FIRST || quest->GetQuestId() > HIDDEN_QUEST_LAST)
            Progress(player, ACTIVITY_QUEST);
    }

    void OnPlayerLevelChanged(Player* player, uint8 oldLevel) override
    {
        if (player->GetLevel() > oldLevel)
            Progress(player, ACTIVITY_LEVEL, 0, player->GetLevel() - oldLevel);
    }

    void OnPlayerAchievementComplete(Player* player, AchievementEntry const* /*achievement*/) override
    {
        // Other modules hand account-wide achievements out while a character loads.
        if (player->GetSession() && !player->GetSession()->PlayerLoading())
            Progress(player, ACTIVITY_ACHIEVEMENT);
    }

    void OnPlayerUpdateGatheringSkill(Player* player, uint32 skillId, uint32 /*current*/, uint32 /*gray*/, uint32 /*green*/,
        uint32 /*yellow*/, uint32& /*gain*/) override
    {
        // The core also comes here for prospecting and milling.
        if (skillId == SKILL_HERBALISM || skillId == SKILL_MINING || skillId == SKILL_SKINNING)
            Progress(player, ACTIVITY_GATHER, skillId);
    }

    bool OnPlayerUpdateFishingSkill(Player* player, int32 /*skill*/, int32 /*zoneSkill*/, int32 chance, int32 roll) override
    {
        if (chance >= roll)
            Progress(player, ACTIVITY_FISH);
        return true;
    }

    // Fires for a spell on any skill line that makes or enchants something: a mage's water too.
    void OnPlayerUpdateCraftingSkill(Player* player, SkillLineAbilityEntry const* skill, uint32 /*currentLevel*/, uint32& /*gain*/) override
    {
        SkillLineEntry const* line = skill ? sSkillLineStore.LookupEntry(skill->SkillLine) : nullptr;
        if (!line || (line->categoryId != SKILL_CATEGORY_PROFESSION && line->categoryId != SKILL_CATEGORY_SECONDARY))
            return;

        // Disenchanting comes here too, and it takes an item apart.
        SpellInfo const* spell = sSpellMgr->GetSpellInfo(skill->Spell);
        if (spell && !spell->HasEffect(SPELL_EFFECT_DISENCHANT))
            Progress(player, ACTIVITY_CRAFT);
    }

    // Fires for each player the core gives an honorable kill, group members included.
    void OnPlayerVictimRewardAfter(Player* player, Player* /*victim*/, uint32& /*killerTitle*/, int32& /*victimRank*/, float& /*honor*/) override
    {
        Progress(player, ACTIVITY_PVP_KILL);
    }
};

class TradingPostBattlegroundScript : public AllBattlegroundScript
{
public:
    TradingPostBattlegroundScript() : AllBattlegroundScript("TradingPostBattlegroundScript",
        { ALLBATTLEGROUNDHOOK_ON_BATTLEGROUND_END_REWARD }) { }

    void OnBattlegroundEndReward(Battleground* bg, Player* player, TeamId winnerTeamId) override
    {
        if (!bg || !player || bg->isArena())
            return;

        Progress(player, ACTIVITY_BG_PLAY);
        if (player->GetBgTeamId() == winnerTeamId)
            Progress(player, ACTIVITY_BG_WIN);
    }
};

class TradingPostGlobalScript : public GlobalScript
{
public:
    TradingPostGlobalScript() : GlobalScript("TradingPostGlobalScript", { GLOBALHOOK_ON_AFTER_UPDATE_ENCOUNTER_STATE }) { }

    // Fires for every creature the core credits in an instance. `encounters` is the instance's
    // boss list; the credit is a boss if it's on it.
    void OnAfterUpdateEncounterState(Map* map, EncounterCreditType type, uint32 creditEntry, Unit* source,
        Difficulty /*difficulty_fixed*/, DungeonEncounterList const* encounters, uint32 /*dungeonCompleted*/, bool updated) override
    {
        if (!Enabled() || !map || !encounters)
            return;

        // A credit spell fires this at every cast; only the first one finishes the boss.
        if (source && source->GetInstanceScript() && !updated)
            return;

        for (DungeonEncounter const* encounter : *encounters)
        {
            if (encounter->creditType != type || encounter->creditEntry != creditEntry)
                continue;

            ActivityType const activity = map->IsRaid() ? ACTIVITY_RAID_BOSS : ACTIVITY_DUNGEON_BOSS;
            for (MapReference const& ref : map->GetPlayers())
                if (Player* player = ref.GetSource())
                    Progress(player, activity);
            return;
        }
    }
};

class npc_trading_post : public CreatureScript
{
public:
    npc_trading_post() : CreatureScript("npc_trading_post") { }

    bool OnGossipHello(Player* player, Creature* creature) override
    {
        ClearGossipMenuFor(player);
        if (!Enabled())
        {
            CloseGossipMenuFor(player);
            ChatHandler(player->GetSession()).SendSysMessage("The Trading Post is closed.");
            return true;
        }

        if (IsRealPlayer(player) && OpenShop(player, creature))
        {
            CloseGossipMenuFor(player);
            return true;
        }

        SendGossipMenuFor(player, player->GetGossipTextId(creature), creature->GetGUID());
        return true;
    }
};

class TradingPostCommandScript : public CommandScript
{
public:
    TradingPostCommandScript() : CommandScript("TradingPostCommandScript") { }

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable tradingPostCommandTable =
        {
            { "",       HandleBalanceCommand, SEC_PLAYER,        Console::No  },
            { "adjust", HandleAdjustCommand,  SEC_ADMINISTRATOR, Console::Yes },
            { "reload", HandleReloadCommand,  SEC_ADMINISTRATOR, Console::Yes },
        };

        static ChatCommandTable commandTable =
        {
            { "tradingpost", tradingPostCommandTable },
        };

        return commandTable;
    }

    static bool HandleBalanceCommand(ChatHandler* handler)
    {
        handler->PSendSysMessage("Your account holds {} Trader's Tender.", Balance(handler->GetSession()->GetAccountId()));
        return true;
    }

    static bool HandleAdjustCommand(ChatHandler* handler, AccountIdentifier account, int32 tender)
    {
        if (!tender)
            return false;

        Adjust(account.GetID(), tender);
        handler->PSendSysMessage("{}'s account holds {} Trader's Tender now.", account.GetName(), Balance(account.GetID()));
        return true;
    }

    static bool HandleReloadCommand(ChatHandler* handler)
    {
        LoadConfig();
        ReloadWorldData();
        handler->SendSysMessage("Trading Post stock and Traveler's Log reloaded.");
        return true;
    }
};

class TradingPostWorldScript : public WorldScript
{
public:
    TradingPostWorldScript() : WorldScript("TradingPostWorldScript",
        { WORLDHOOK_ON_AFTER_CONFIG_LOAD, WORLDHOOK_ON_STARTUP, WORLDHOOK_ON_UPDATE, WORLDHOOK_ON_SHUTDOWN }) { }

    void OnAfterConfigLoad(bool /*reload*/) override
    {
        LoadConfig();
    }

    void OnStartup() override
    {
        LoadAll();
    }

    void OnUpdate(uint32 diff) override
    {
        Update(diff);
    }

    void OnShutdown() override
    {
        SaveProgress();
    }
};

void AddTradingPostScripts()
{
    new TradingPostPlayerScript();
    new TradingPostBattlegroundScript();
    new TradingPostGlobalScript();
    new npc_trading_post();
    new TradingPostCommandScript();
    new TradingPostWorldScript();
}
