-- Smoke test for the TradingPost addon outside the game: stubs just enough of the 3.3.5a API, loads
-- the addon in .toc order and plays a fake server through the real protocol code.
-- Usage (any Lua 5.3+): lua tools/addon_smoke_test.lua addon/TradingPost
-- DRAGON=1 adds a DragonUI stand-in, JOURNAL=1 a Journal stand-in that takes tabs, HORDE=1 plays the Horde.

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
function methods:SetModelScale(scale) self.__scale = scale end
function methods:SetPosition(depth, x, y) self.__x, self.__y = x, y end
function methods:SetFacing(facing) self.__facing = facing end
function methods:SetCreature(entry) self.__scaleAtLoad = self.__scale; self.__creature = entry; if self.__records and self.__records[entry] then self.__model = "x.m2" end end
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
function UnitFactionGroup() return os.getenv("HORDE") == "1" and "Horde" or "Alliance" end
local cursorX, buttonsDown = 0, {}
function GetCursorPosition() return cursorX, 0 end
function IsMouseButtonDown(button) return buttonsDown[button] end
function time() return math.floor(now or 0) end
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

events.__scripts.OnEvent(events, "ADDON_LOADED", "TradingPost")
check(TradingPostDB.modelViews == ModelViewLib.views, "views are saved with the addon")

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

-- What's under way comes first and what's finished sinks; the filters narrow it down.
do
	local rows, filters = {}, {}
	for _, f in ipairs(frames) do
		if f.paper then rows[#rows + 1] = f end
		if f.filter then filters[f.filter.key] = f end
	end
	check(rows[1].name:GetText() == "Keeping the Roads Clear" and rows[2].name:GetText() == "Odd Jobs", "finished activities sink")
	check(rows[2].check:IsShown() and not rows[2].bar:IsShown(), "a finished activity is ticked off")
	check(rows[1].bar:IsShown() and rows[1].bar.text:GetText() == "11 / 200", "one under way shows how far")
	filters.done.__scripts.OnClick(filters.done)
	check(rows[1].name:GetText() == "Odd Jobs" and not rows[2]:IsShown(), "the Completed filter")
	check(filters.done.count:GetText() == "1" and filters.all.count:GetText() == "2", "filters count")
	filters.all.__scripts.OnClick(filters.all)
	check(rows[2]:IsShown(), "back to all")
end

-- The bonus item's details can land after the state, and its name follows when they do.
do
	local panel = journal and tabs.travelerslog.panel
	for _, f in ipairs(frames) do
		if f.bonusWatch then panel = f end
	end
	itemsKnown = false
	server("S:900:202611:175:1000:0:0:500:500:864000:0:401")
	check(panel.bonus.name:GetText() == "" and panel.bonusWatch:IsShown(), "waits for the bonus item's name")
	itemsKnown = true
	tick(1)
	check(panel.bonus.name:GetText():find("^Armored Irontusk\n") and not panel.bonusWatch:IsShown(), "and shows it when it lands")
	check(panel.bonus.name:GetText():find("at 1000 points", 1, true), "and when it comes")

	-- The milestones: a diamond on the bar for each, and the next one's reward in the column.
	check(#panel.markers == 1, "one diamond before the milestones are known")
	check(panel.rewardTitle:GetText() == "Next Reward: 1000 Points" and panel.rewardTender:GetText() == "500", "the whole reward before they're known")
	server("G:250:100:500:100:750:100:1000:200")
	server("S:900:202611:300:1000:0:0:500:500:864000:0:401")
	check(#T.milestones == 4 and T.milestones[2].points == 500 and T.milestones[4].tender == 200, "milestones read")
	check(#panel.markers == 4, "a diamond for each milestone")
	check(panel.rewardTitle:GetText() == "Next Reward: 500 Points" and panel.rewardTender:GetText() == "100", "the next milestone: " .. panel.rewardTitle:GetText())
	server("S:900:202611:750:1000:0:0:500:500:864000:0:401")
	check(panel.rewardTitle:GetText() == "Next Reward: 1000 Points" and panel.rewardTender:GetText() == "200", "a milestone reached moves on")
	server("S:900:202611:1000:1000:0:1:500:500:864000:0:401")
	check(panel.rewardTitle:GetText():find("Reward Earned", 1, true) and panel.rewardTender:GetText() == "500", "all earned")
	server("G:1000:500")
	server("S:900:202611:175:1000:0:0:500:500:864000:0:401")
	check(panel.markers[1]:IsShown() and not panel.markers[2]:IsShown(), "fewer milestones hide the spare diamonds")
	server("G:250:100:500:100:750:100:1000:200")
	server("S:900:202611:175:1000:0:0:500:500:864000:0:401")
end

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

-- The preview: each creature keeps the view it was given, and every load starts from neutral.
do
	local model = shop.model
	model.__records = { [9001] = true, [9002] = true, [9003] = true }
	-- One pass sets the creature again and it draws; the next one frames it.
	tick(1)
	tick(1)
	check(model.__model == "x.m2" and model.__scale == 1, "an untouched creature has the default view")
	check(next(ModelViewLib.views) == nil, "looking at one saves nothing")

	model.__scripts.OnMouseWheel(model, -1)
	local zoomed = model.__scale
	check(zoomed < 1, "the wheel zooms out")
	buttonsDown.LeftButton = true
	model.__scripts.OnMouseDown(model, "LeftButton")
	cursorX = 100
	tick(0.1)
	check(math.abs(model.__facing - 1.7) < 0.001, "a drag turns it")
	buttonsDown.LeftButton = nil
	tick(0.1)
	cursorX = 200
	tick(0.1)
	check(math.abs(model.__facing - 1.7) < 0.001, "letting go stops the turning")
	buttonsDown.RightButton = true
	model.__scripts.OnMouseDown(model, "RightButton")
	cursorX = 300
	tick(0.1)
	buttonsDown.RightButton = nil
	check(model.__x and model.__x > 1, "a right drag moves it")
	local moved = model.__x

	local function choose(item)
		for _, f in ipairs(frames) do
			if f.good and f.good.item == item then f.__scripts.OnClick(f) return end
		end
	end
	choose(403)
	check(model.__creature == 9003 and model.__scaleAtLoad == 1, "the next creature loads from neutral")
	check(model.__scale == 1 and model.__x == 0, "and has its own view")
	check(math.abs(model.__facing - 0.5) < 0.001, "and its own facing")
	choose(401)
	check(model.__scaleAtLoad == 1, "a zoomed creature loads from neutral too")
	check(model.__scale == zoomed and model.__x == moved, "coming back restores the view")
	check(math.abs(model.__y - -0.15 * (zoomed - 1)) < 0.001, "the height follows the zoom, which is anchored on the feet")
	-- The swap lands a few frames after the call and takes the scale with it.
	model.__scale = 1
	tick(0.1)
	check(model.__scale == zoomed, "the view is set again while the swap lands")
	tick(2)
	model.__scale = 1
	tick(0.1)
	check(model.__scale == 1, "and only for a moment")
	model.__scale = zoomed

	-- With the hold on, the model stays neutral through the landing and takes its view after.
	ModelViewLib.holdSeconds = 0.3
	choose(403)
	choose(401)
	check(model.__scale == 1, "held: no view yet")
	tick(0.1)
	check(model.__scale == 1, "held: still none")
	tick(0.3)
	tick(0.1)
	check(model.__scale == zoomed, "held: the view comes after")
	-- A long frame, as a slow model load makes, runs out the hold and the settling at once.
	choose(403)
	choose(401)
	tick(5)
	check(model.__scale == zoomed, "held: a long frame still sets the view")
	ModelViewLib.holdSeconds = 0
	tick(2)

	-- A reply while the interface is hidden (Alt-Z) loads nothing, and showing again does.
	local loads = 0
	local setCreature = methods.SetCreature
	methods.SetCreature = function (self, entry) loads = loads + 1; setCreature(self, entry) end
	model.__scripts.OnHide(model)
	model.__shown = false
	T.ShowCreature(model, 9001)
	check(loads == 0, "a hidden model doesn't load")
	model.__shown = true
	model.__scripts.OnShow(model)
	check(loads == 1 and model.__scale == zoomed, "showing it again loads it, with its view")
	methods.SetCreature = setCreature
	tick(2)

	-- In the client a window's children hear OnHide with it; here the model is told by hand.
	shop:Hide()
	model.__scripts.OnHide(model)
	check(model.__scale == 1, "a hidden model is left neutral")
	server("OPEN")
	server("SI:401^600^0^0^9001^1^")
	server("SI:402^800^2^0^9002^1^Comes to the realm with The Burning Crusade.")
	server("SI:403^250^1^0^9003^2^")
	server("SE")
	check(model.__scaleAtLoad == 1 and model.__scale == zoomed, "reopening restores the view")

	model.__scripts.OnMouseDown(model, "MiddleButton")
	check(model.__scale == 1 and model.__x == 0 and ModelViewLib.views[9001] == nil, "a middle click resets it")

	-- How far it moves grows with the zoom, and comes back in with it.
	buttonsDown.RightButton = true
	model.__scripts.OnMouseDown(model, "RightButton")
	cursorX = cursorX + 5000
	tick(0.1)
	check(model.__x == 1.5, "moving stops at the limit")
	for _ = 1, 12 do model.__scripts.OnMouseWheel(model, 1) end
	check(model.__scale == 4, "zooming in stops at the limit")
	cursorX = cursorX + 5000
	tick(0.1)
	check(model.__x == 6, "zoomed in, it moves further")
	for _ = 1, 12 do model.__scripts.OnMouseWheel(model, -1) end
	check(model.__x == 1.5, "zooming back out brings it back in")
	buttonsDown.RightButton = nil
	tick(0.1)
	model.__scripts.OnMouseDown(model, "MiddleButton")

	-- Saved views from another addon: the later change to a creature wins.
	ModelViewLib.views[77] = { zoom = 2, at = 50 }
	ModelViewLib.Bind({ modelViews = { [77] = { zoom = 3, at = 10 }, [78] = { zoom = 3, at = 10 } } })
	check(ModelViewLib.views[77].zoom == 2 and ModelViewLib.views[78].zoom == 3, "older views don't overwrite newer ones")
	ModelViewLib.Bind({ modelViews = { [77] = { zoom = 4, at = 90 } } })
	check(ModelViewLib.views[77].zoom == 4, "a newer view wins")
	ModelViewLib.views[77], ModelViewLib.views[78] = nil, nil

	-- A second copy of the file, as another addon brings: it changes nothing, and a newer one keeps
	-- the views.
	ModelViewLib.views[79] = { zoom = 2, at = 1 }
	local lib = ModelViewLib
	local wire = lib.Wire
	assert(loadfile(addonDir .. "/ModelView.lua"))()
	check(ModelViewLib == lib and lib.Wire == wire, "the same version doesn't replace itself")
	lib.version = 0
	assert(loadfile(addonDir .. "/ModelView.lua"))()
	check(ModelViewLib == lib and lib.Wire ~= wire and lib.views[79].zoom == 2, "a newer copy keeps the views")
	lib.views[79] = nil
end

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
check(shop.hold.good and shop.hold.good.item == 401 and shop.frost:IsShown(), "a frozen good sits in the slot, frost on the stage")
for _, f in ipairs(frames) do
	check(not (f.good and f.good.item == 401 and f ~= shop.hold and f:IsShown()), "and leaves the list")
end
shop.freeze.__scripts.OnClick(shop.freeze)
check(popups[#popups].which == "TRADINGPOST_THAW", "thawing asks first")

-- A frozen good the stock no longer lists still shows in the slot, so it agrees with Freeze.
server("S:900:202611:175:1000:0:0:500:500:864000:402:401")
server("SI:401^600^0^0^9001^1^")
server("SE")
check(shop.hold.good == nil and shop.hold.name:GetText() == "Amber Skitterfly", "the slot names what the state says is frozen")
server("S:900:202611:175:1000:0:0:500:500:864000:0:401")

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
