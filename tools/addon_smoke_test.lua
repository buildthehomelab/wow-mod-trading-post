-- Smoke test for the TradingPost addon outside the game: stubs just enough of the 3.3.5a API, loads
-- the addon in .toc order and plays a fake server through the real protocol code.
-- Usage (any Lua 5.3+): lua tools/addon_smoke_test.lua addon/TradingPost
-- DRAGON=1 adds a DragonUI stand-in, JOURNAL=1 a Journal stand-in that takes tabs.

local addonDir = arg[1] or "addon/TradingPost"
local dragon = os.getenv("DRAGON") == "1"
local journal = os.getenv("JOURNAL") == "1"

local now = 100
function GetTime() return now end

local failures = 0
local function check(condition, what)
	if not condition then
		failures = failures + 1
		print("FAIL: " .. what)
	end
end

-- Not in a 3.3.5a client, whatever later clients have: using one breaks in the game.
local NOT_IN_335 = { SetShown = true, SetColorTexture = true, SetAtlas = true, SetObeyStepOnDrag = true }

local frameMeta = {}
local methods = {}

local function newObject(kind, name, parent)
	local o = { __kind = kind, __name = name, __scripts = {}, __shown = true, __text = "", __parent = parent, __level = 1, __enabled = true }
	setmetatable(o, frameMeta)
	if name then _G[name] = o end
	return o
end

frameMeta.__index = function (t, k)
	if methods[k] then return methods[k] end
	if NOT_IN_335[k] then error("not in a 3.3.5a client: " .. k, 2) end
	if type(k) == "string" and k:match("^%u") then return function () end end
	return nil
end

function methods:SetScript(event, fn) self.__scripts[event] = fn end
function methods:GetScript(event) return self.__scripts[event] end
function methods:HookScript(event, fn)
	local old = self.__scripts[event]
	self.__scripts[event] = function (...) if old then old(...) end fn(...) end
end
function methods:Show()
	local was = self.__shown
	self.__shown = true
	if not was and self.__scripts.OnShow then self.__scripts.OnShow(self) end
end
function methods:Hide()
	local was = self.__shown
	self.__shown = false
	if was and self.__scripts.OnHide then self.__scripts.OnHide(self) end
end
function methods:IsShown() return self.__shown end
function methods:IsVisible()
	local o = self
	while o do
		if not o.__shown then return false end
		o = o.__parent
	end
	return true
end
function methods:SetText(text) self.__text = text == nil and "" or tostring(text) end
function methods:GetText() return self.__text end
function methods:CreateTexture() return newObject("Texture", nil, self) end
function methods:CreateFontString() return newObject("FontString", nil, self) end
function methods:RegisterEvent(event) self.__events = self.__events or {}; self.__events[event] = true end
function methods:Enable() self.__enabled = true end
function methods:Disable() self.__enabled = false end
function methods:IsEnabled() return self.__enabled end
function methods:GetFrameLevel() return self.__level end
function methods:GetWidth() return 300 end
function methods:GetHeight() return 300 end
function methods:GetModel() return self.__model end
function methods:SetCreature(entry) self.__creature = entry; if self.__records and self.__records[entry] then self.__model = "x.m2" end end
function methods:ClearModel() self.__model = nil end
function methods:SetValue(value) self.__value = value end

local frames = {}
function CreateFrame(kind, name, parent, template)
	local f = newObject(kind, name, parent)
	table.insert(frames, f)
	return f
end

UIParent = newObject("Frame", "UIParent")
UISpecialFrames = {}
SlashCmdList = {}
StaticPopupDialogs = {}
ITEM_QUALITY_COLORS = { [1] = { r = 1, g = 1, b = 1 }, [4] = { r = 0.6, g = 0.2, b = 0.9 } }
YES, NO, OKAY, CANCEL = "Yes", "No", "Okay", "Cancel"
GameTooltip = newObject("GameTooltip", "GameTooltip")
DEFAULT_CHAT_FRAME = { AddMessage = function (_, text) print("chat: " .. text) end }
function UnitName() return "Tester" end
function GetCursorPosition() return 0, 0 end
function PlaySound() end

local itemNames = { [401] = "Armored Irontusk", [402] = "Amber Skitterfly", [403] = "Pet Rock" }
local itemsKnown = true
function GetItemInfo(item)
	if not itemsKnown or not itemNames[item] then return nil end
	return itemNames[item], "item:" .. item, 4, 60, 20, "Misc", "Mount", 1, "", "Interface\\Icons\\X"
end

local popups = {}
function StaticPopup_Show(which, a, b)
	local popup = { which = which, a = a, b = b }
	table.insert(popups, popup)
	return popup
end

local sent = {}
function SendAddonMessage(prefix, message, channel, target)
	check(prefix == "TPOST", "prefix " .. tostring(prefix))
	check(channel == "WHISPER" and target == "Tester", "whispers itself")
	table.insert(sent, message)
end

if dragon then
	NineSliceUtils = { GetLayout = function () return {} end, ApplyLayout = function () end }
	DragonUI = {
		_dir = "Interface\\AddOns\\DragonUI\\", atlasinfo = {}, SafeSetAtlas = function () return true end,
		SkinRedButton = function () end, CharacterPanel = { ReskinTab = function () end, ModernizeCloseButton = function () end },
	}
end

local tabs = {}
local openedTab
if journal then
	Journal = {
		API = 1,
		RegisterTab = function (spec)
			tabs[spec.key] = spec
			spec.panel = newObject("Frame")
		end,
		OpenTab = function (key)
			openedTab = key
			local spec = tabs[key]
			if spec.build then spec.build(spec.panel); spec.build = nil end
			if spec.onShow then spec.onShow(spec.panel) end
			return true
		end,
	}
end

-- Load in .toc order.
local toc = assert(io.open(addonDir .. "/TradingPost.toc"))
local eventFrames
for raw in toc:lines() do
	local line = raw:gsub("\r", "")
	if line:match("%.lua$") then
		assert(loadfile(addonDir .. "/" .. line))()
		if line == "Core.lua" then eventFrames = #frames end
	end
end
toc:close()

local T = TradingPost
local events
for i = 1, eventFrames do
	if frames[i].__events and frames[i].__events.CHAT_MSG_ADDON then events = frames[i] end
end
assert(events, "the event frame")

local function tick(seconds)
	now = now + seconds
	for _, f in ipairs(frames) do
		if f.__shown and f.__scripts.OnUpdate then f.__scripts.OnUpdate(f, seconds) end
	end
end

local function server(message)
	events.__scripts.OnEvent(events, "CHAT_MSG_ADDON", "TPOST", message, "WHISPER", "Tester")
end

local function sentThing(message)
	for _, m in ipairs(sent) do
		if m == message then return true end
	end
	return false
end

-- Hello, tried until answered.
events.__scripts.OnEvent(events, "PLAYER_ENTERING_WORLD")
tick(2)
check(sentThing("HELLO:1"), "says hello")
sent = {}
server("H:1")
check(T.ready, "ready after the answer")
tick(6)
check(not sentThing("HELLO:1"), "stops saying hello")

server("S:900:202611:75:1000:0:0:500:500:864000:0:401")
server("T:Year's End Vault^The back room, opened up.")
check(T.state.balance == 900 and T.state.bonus == 401 and T.state.cachePays == 500, "state read")
check(T.theme.name == "Year's End Vault", "theme read")
check(T.DaysLeftText() == "10 days left", "days left: " .. T.DaysLeftText())

-- The Traveler's Log.
T.OpenLog()
if journal then check(openedTab == "travelerslog", "opens the Journal tab") end
check(sentThing("LOG"), "asks for the log")
server("LA:1^200^10^75^Keeping the Roads Clear^Defeat 200 enemies.")
server("LA:2^25^25^100^Odd Jobs^Turn in 25 quests.")
server("LE")
check(#T.activities == 2 and T.activities[1].progress == 10, "activities read")
server("P:1:11:175")
check(T.activities[1].progress == 11 and T.state.points == 175, "one activity moves")
server("P:99:1:175")   -- not on the list: nothing happens

-- The shop.
sent = {}
server("OPEN")
local shop = _G.TradingPostFrame
check(shop and shop:IsShown(), "OPEN shows the window")
check(sentThing("STOCK") and sentThing("STATE"), "asks for the stock")
itemsKnown = false
server("SI:401^600^0^0^9001^1^")
server("SI:402^800^2^0^9002^1^Comes to the realm with The Burning Crusade.")
server("SI:403^250^1^0^9003^2^")
server("SE")
check(#T.stock == 3 and T.stock[2].unlock:find("Burning", 1, true), "stock read")
check(shop.detailName:GetText() == "Item 401", "first good chosen, its name not landed yet")
check(shop.model.__creature == 9001, "first good's creature shown")
check(sentThing("R:9001"), "asks for the creature record")
itemsKnown = true
tick(1)
check(shop.detailName:GetText() == "Armored Irontusk", "name appears when it lands")
check(shop.buy:IsEnabled(), "can buy with 900 Tender")

-- A locked good can't be bought or frozen.
local rowOf = {}
for _, f in ipairs(frames) do
	if f.good then rowOf[f.good.item] = f end
end
rowOf[402].__scripts.OnClick(rowOf[402])
check(not shop.buy:IsEnabled() and not shop.freeze:IsEnabled(), "locked: no buying, no freezing")
check(shop.detailStatus:GetText():find("Burning", 1, true), "locked: says why")
rowOf[403].__scripts.OnClick(rowOf[403])
check(not shop.buy:IsEnabled(), "owned: no buying")

-- Buying asks first.
rowOf[401].__scripts.OnClick(rowOf[401])
sent = {}
shop.buy.__scripts.OnClick(shop.buy)
check(popups[#popups].which == "TRADINGPOST_BUY", "buying asks first")
check(not sentThing("BUY:401"), "nothing bought yet")
StaticPopupDialogs.TRADINGPOST_BUY.OnAccept(popups[#popups], 401)
check(sentThing("BUY:401"), "buys when told yes")
sent = {}
server("B:401:1")
check(sentThing("STOCK"), "reads the stock again after buying")

-- Too dear.
server("S:100:202611:175:1000:0:0:500:500:864000:0:401")
check(not shop.buy:IsEnabled(), "not enough Tender: no buying")

-- Freezing: straight away the first time, asking when it replaces another.
server("S:900:202611:175:1000:0:0:500:500:864000:0:401")
sent = {}
shop.freeze.__scripts.OnClick(shop.freeze)
check(sentThing("FREEZE:401"), "freezes")
server("F:401")
server("S:900:202611:175:1000:0:0:500:500:864000:403:401")
sent = {}
shop.freeze.__scripts.OnClick(shop.freeze)
check(popups[#popups].which == "TRADINGPOST_FREEZE", "replacing a frozen good asks first")

-- A frozen good says so and thaws.
server("SI:401^600^0^1^9001^1^")
server("SE")
check(shop.freeze:GetText() == "Thaw", "a frozen good offers Thaw")
shop.freeze.__scripts.OnClick(shop.freeze)
check(popups[#popups].which == "TRADINGPOST_THAW", "thawing asks first")

-- The cache.
sent = {}
shop.cache.__scripts.OnClick(shop.cache)
check(sentThing("CACHE"), "claims the cache")
server("C:1")
server("S:1400:202611:175:1000:1:0:500:500:864000:0:401")
check(not shop.cache:IsEnabled(), "the cache is taken")

-- More goods than rows must not break the window.
for item = 1000, 1030 do server("SI:" .. item .. "^1^0^0^0^1^") end
server("SE")

-- Walking off.
server("E:You need to be at the Trading Post for that.")
check(not shop:IsShown(), "closes when too far away")

-- A new month.
sent = {}
server("M")
check(sentThing("STATE") and sentThing("LOG"), "a new month reads everything again")

-- Unknown commands are ignored.
server("ZZZ:1")
server("garbage")

if failures > 0 then
	print(failures .. " check(s) failed")
	os.exit(1)
end
print("TradingPost smoke test passed" .. (dragon and " (DragonUI)" or "") .. (journal and " (Journal)" or ""))
