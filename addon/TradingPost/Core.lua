-- Trading Post: the conversation with the server. Messages are whispers to oneself on prefix TPOST;
-- src/TradingPost.cpp of the mod-trading-post module lists them. What arrives goes into T.state,
-- T.activities and T.stock, and listeners hear about it through T.On.

TradingPost = TradingPost or {}
local T = TradingPost

T.PREFIX = "TPOST"
T.PROTOCOL = 1
T.STATUS_FOR_SALE, T.STATUS_OWNED, T.STATUS_LOCKED, T.STATUS_SELF_FOUND = 0, 1, 2, 3

T.state = nil
T.theme = { name = "", description = "" }
T.activities = {}
T.stock = {}
T.ready = false

local listeners = {}

function T.On(event, fn)
	listeners[event] = listeners[event] or {}
	table.insert(listeners[event], fn)
end

function T.Fire(event, ...)
	for _, fn in ipairs(listeners[event] or {}) do fn(...) end
end

function T.Send(message)
	SendAddonMessage(T.PREFIX, message, "WHISPER", UnitName("player"))
end

function T.Print(text)
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Trading Post:|r " .. text)
end

-- Splits on ^; an empty field stays an empty string.
local function split(text)
	local fields = {}
	local start = 1
	while true do
		local at = text:find("^", start, true)
		if not at then
			fields[#fields + 1] = text:sub(start)
			return fields
		end
		fields[#fields + 1] = text:sub(start, at - 1)
		start = at + 1
	end
end

local loadingActivities, loadingStock = nil, nil

local handlers = {}

function handlers.H(rest)
	T.ready = true
	T.Fire("READY", tonumber(rest))
end

function handlers.S(rest)
	local v = {}
	for number in rest:gmatch("[^:]+") do v[#v + 1] = tonumber(number) or 0 end
	T.state = {
		balance = v[1] or 0, month = v[2] or 0, points = v[3] or 0, needed = v[4] or 1000,
		cacheTaken = v[5] == 1, logDone = v[6] == 1, cachePays = v[7] or 0, logPays = v[8] or 0,
		secondsLeft = v[9] or 0, frozen = v[10] or 0, bonus = v[11] or 0, at = GetTime(),
	}
	T.Fire("STATE")
end

function handlers.T(rest)
	local fields = split(rest)
	T.theme = { name = fields[1] or "", description = fields[2] or "" }
	T.Fire("STATE")
end

function handlers.LA(rest)
	local f = split(rest)
	loadingActivities = loadingActivities or {}
	loadingActivities[#loadingActivities + 1] = {
		id = tonumber(f[1]), amount = tonumber(f[2]) or 1, progress = tonumber(f[3]) or 0,
		points = tonumber(f[4]) or 0, name = f[5] or "", description = f[6] or "",
	}
end

function handlers.LE()
	T.activities = loadingActivities or {}
	loadingActivities = nil
	T.Fire("LOG")
end

function handlers.P(rest)
	local id, progress, points = rest:match("^(%d+):(%d+):(%d+)$")
	id, progress, points = tonumber(id), tonumber(progress), tonumber(points)
	if not id then return end
	for _, activity in ipairs(T.activities) do
		if activity.id == id then activity.progress = progress end
	end
	if T.state then T.state.points = points end
	T.Fire("LOG")
	T.Fire("STATE")
end

function handlers.SI(rest)
	local f = split(rest)
	loadingStock = loadingStock or {}
	loadingStock[#loadingStock + 1] = {
		item = tonumber(f[1]), price = tonumber(f[2]) or 0, status = tonumber(f[3]) or 0, frozen = f[4] == "1",
		creature = tonumber(f[5]) or 0, kind = tonumber(f[6]) or 0, unlock = f[7] or "",
	}
end

function handlers.SE()
	T.stock = loadingStock or {}
	loadingStock = nil
	T.Fire("STOCK")
end

function handlers.OPEN()
	T.Fire("OPEN")
end

-- A new month: everything shown is out of date.
function handlers.M()
	T.Send("STATE")
	T.Send("LOG")
	T.Fire("MONTH")
end

function handlers.B(rest)
	local item, success = rest:match("^(%d+):(%d)$")
	T.Fire("BOUGHT", tonumber(item), success == "1")
end

function handlers.C(rest)
	T.Fire("CACHE", rest == "1")
end

function handlers.F(rest)
	T.Fire("FROZEN", tonumber(rest))
end

function handlers.E(rest)
	T.Print(rest)
	T.Fire("REFUSED", rest)
end

local function onMessage(message)
	local command, rest = message:match("^(%u+):?(.*)$")
	local handler = command and handlers[command]
	if handler then handler(rest) end
end

-- Without the server module nothing answers the hello, so it's tried a few times and then left.
local HELLO_TRIES, HELLO_EVERY = 4, 5

local events = CreateFrame("Frame")
local helloLeft, helloWait = 0, 0
events:Hide()
events:SetScript("OnUpdate", function (self, elapsed)
	helloWait = helloWait - elapsed
	if helloWait > 0 then return end
	if T.ready or helloLeft <= 0 then
		self:Hide()
		return
	end
	helloLeft = helloLeft - 1
	helloWait = HELLO_EVERY
	T.Send("HELLO:" .. T.PROTOCOL)
end)

events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function (self, event, prefix, message, _, sender)
	if event == "PLAYER_ENTERING_WORLD" then
		if not T.ready then
			helloLeft, helloWait = HELLO_TRIES, 1
			self:Show()
		end
	elseif prefix == T.PREFIX and sender == UnitName("player") then
		onMessage(message)
	end
end)

function T.DaysLeftText()
	local state = T.state
	if not state then return "" end
	local left = state.secondsLeft - (GetTime() - state.at)
	if left <= 0 then return "Ends today" end
	local days = math.ceil(left / 86400)
	if days == 1 then return "Ends today" end
	return days .. " days left"
end

function T.ItemName(item)
	local name = GetItemInfo(item)
	return name
end

function T.ItemIcon(item)
	local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(item)
	return texture or "Interface\\Icons\\INV_Misc_QuestionMark"
end

function T.ItemQuality(item)
	local _, _, quality = GetItemInfo(item)
	return quality or 1
end

-- Reads from the item link, the path that survives an item the client hasn't cached.
function T.ShowItemTooltip(owner, item)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetHyperlink("item:" .. item)
	GameTooltip:Show()
end
