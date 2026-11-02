-- Trading Post: the proprietor's window. Opens when the server says so, after talking to one. Laid
-- out like retail's: the month's goods and the frozen slot on the left, the chosen one turning on
-- the right, the wallet at the top.

local T = TradingPost

local WIDTH, HEIGHT = 900, 600
local ROW_HEIGHT = 32
local LIST_WIDTH = 356
local PANE_INSET = 18   -- how far in a framed pane's art draws its line

local frame, selected
local rows = {}
local namesMissing = 0

local function goodNamed(item)
	return T.ItemName(item) or ("Item " .. item)
end

local function selectedGood()
	for _, good in ipairs(T.stock) do
		if good.item == selected then return good end
	end
end

local KIND_NAMES = { [1] = "Mount", [2] = "Companion" }

local function statusLine(good)
	if good.status == T.STATUS_OWNED then return "|cff33cc33You own this.|r" end
	if good.status == T.STATUS_LOCKED then return "|cffff8040" .. good.unlock .. "|r" end
	if good.status == T.STATUS_SELF_FOUND then return "|cffff8040Self-Found characters can't buy from the Trading Post.|r" end
	if good.frozen then return "|cff66ccffFrozen: it stays on sale for you until you buy it.|r" end
	return ""
end

local function refreshDetail()
	local good = selectedGood()
	frame.frost:Hide()
	frame.buyGlow:Hide()
	if not good then
		T.ShowCreature(frame.model, nil)
		frame.detailName:SetText("")
		frame.detailKind:SetText("")
		frame.detailPrice:SetText("")
		frame.detailCoin:Hide()
		frame.detailStatus:SetText("")
		T.SetEnabled(frame.buy, false)
		T.SetEnabled(frame.freeze, false)
		frame.freeze:SetText("Freeze")
		return
	end

	T.ShowCreature(frame.model, good.creature)
	frame.detailName:SetText(goodNamed(good.item))
	local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[T.ItemQuality(good.item)]
	if color then frame.detailName:SetTextColor(color.r, color.g, color.b) end
	frame.detailKind:SetText(KIND_NAMES[good.kind] or "")
	frame.detailPrice:SetText(good.price)
	frame.detailCoin:Show()
	frame.detailStatus:SetText(statusLine(good))
	T.SetShown(frame.frost, good.frozen)

	local forSale = good.status == T.STATUS_FOR_SALE
	local balance = T.state and T.state.balance or 0
	local canBuy = forSale and balance >= good.price
	T.SetEnabled(frame.buy, canBuy)
	T.SetShown(frame.buyGlow, canBuy)
	T.SetEnabled(frame.freeze, forSale)
	frame.freeze:SetText(good.frozen and "Thaw" or "Freeze")
end

local function fillPrice(row, good)
	local owned = good.status == T.STATUS_OWNED
	local locked = good.status == T.STATUS_LOCKED
	row.coin:Hide()
	row.mark:Hide()
	if owned then
		row.price:SetText("|cff33cc33Owned|r")
		T.Art(row.mark, "post", "owned_small", true)
		row.mark:Show()
	elseif locked then
		row.price:SetText("|cff999999Locked|r")
		T.Art(row.mark, "log", "icon_lock")
		row.mark:SetSize(12, 15)
		row.mark:Show()
	else
		row.price:SetText(good.price)
		row.coin:Show()
	end
	row.icon:SetDesaturated(locked)
	row.icon:SetAlpha((owned or locked) and 0.6 or 1)
end

local function refreshHold()
	local good
	for _, candidate in ipairs(T.stock) do
		if candidate.frozen then good = candidate end
	end
	local hold = frame.hold
	hold.good = good
	-- The state can name a frozen item the stock doesn't list, if it has left the shop's tables.
	local item = good and good.item or (T.state and T.state.frozen or 0)
	hold.item = item
	if item ~= 0 then
		if not T.ItemName(item) then namesMissing = namesMissing + 1 end
		hold.icon:SetTexture(T.ItemIcon(item))
		hold.icon:Show()
		hold.ice:Show()
		hold.title:SetText("|cff66ccffFrozen|r")
		hold.name:SetText(goodNamed(item))
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[T.ItemQuality(item)]
		if color then hold.name:SetTextColor(color.r, color.g, color.b) end
	else
		hold.icon:Hide()
		hold.ice:Hide()
		hold.title:SetText("|cff808080Nothing frozen|r")
		hold.name:SetText("Freeze a good to keep it on sale after the month.")
		hold.name:SetTextColor(0.6, 0.6, 0.6)
	end
	T.SetShown(hold.selected, good ~= nil and good.item == selected)
end

local function refreshList()
	namesMissing = 0
	local shown = 0
	for _, good in ipairs(T.stock) do
		if not T.ItemName(good.item) then namesMissing = namesMissing + 1 end
		local row = rows[shown + 1]
		-- The frozen good has its slot under the list.
		if row and not good.frozen then
			shown = shown + 1
			row.good = good
			row.icon:SetTexture(T.ItemIcon(good.item))
			row.name:SetText(goodNamed(good.item))
			local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[T.ItemQuality(good.item)]
			if color then row.name:SetTextColor(color.r, color.g, color.b) end
			fillPrice(row, good)
			local chosen = good.item == selected
			T.SetShown(row.highlight, chosen)
			T.SetShown(row.lines, chosen)
			T.SetShown(row.flare, chosen)
			T.Art(row.border, "post", chosen and "border_square_gold" or "border_square_gray")
			row:Show()
		end
	end
	for index = shown + 1, #rows do
		rows[index].good = nil
		rows[index]:Hide()
	end
	refreshHold()
end

local function refreshHeader()
	local state = T.state
	if not state then return end
	frame.theme:SetText(T.theme.name)
	frame.themeText:SetText(T.theme.description)
	frame.left:SetText(T.DaysLeftText())
	frame.tender:SetText(state.balance)
	frame.cache:SetText(state.cacheTaken and "Cache collected" or ("Collector's Cache (" .. state.cachePays .. ")"))
	T.SetEnabled(frame.cache, not state.cacheTaken)
end

local function refresh()
	if not frame or not frame:IsShown() then return end
	refreshHeader()
	refreshList()
	refreshDetail()
end

StaticPopupDialogs["TRADINGPOST_BUY"] = {
	text = "Buy %s for %d Trader's Tender?",
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function (self, item) T.Send("BUY:" .. item) end,
	timeout = 0, whileDead = 1, hideOnEscape = 1,
}

StaticPopupDialogs["TRADINGPOST_FREEZE"] = {
	text = "%s is frozen now. Freezing this instead puts that one back on the shelf. If it isn't this month's, it leaves with the month.",
	button1 = OKAY or "Okay",
	button2 = CANCEL or "Cancel",
	OnAccept = function (self, item) T.Send("FREEZE:" .. item) end,
	timeout = 0, whileDead = 1, hideOnEscape = 1,
}

StaticPopupDialogs["TRADINGPOST_THAW"] = {
	text = "Thaw %s? If it isn't this month's, it leaves the shelves.",
	button1 = OKAY or "Okay",
	button2 = CANCEL or "Cancel",
	OnAccept = function () T.Send("FREEZE:0") end,
	timeout = 0, whileDead = 1, hideOnEscape = 1,
}

local function onBuy()
	local good = selectedGood()
	if not good then return end
	local popup = StaticPopup_Show("TRADINGPOST_BUY", goodNamed(good.item), good.price)
	if popup then popup.data = good.item end
end

local function onFreeze()
	local good = selectedGood()
	if not good then return end
	if good.frozen then
		StaticPopup_Show("TRADINGPOST_THAW", goodNamed(good.item))
		return
	end
	local current = T.state and T.state.frozen or 0
	if current ~= 0 then
		local popup = StaticPopup_Show("TRADINGPOST_FREEZE", goodNamed(current))
		if popup then popup.data = good.item end
	else
		T.Send("FREEZE:" .. good.item)
	end
end

local function selectRow(self)
	if self.good then
		selected = self.good.item
		refresh()
	end
end

local function showRowTooltip(self)
	if self.good then T.ShowItemTooltip(self, self.good.item) end
end

local function makeRow(parent, index)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", PANE_INSET, -PANE_INSET - (index - 1) * ROW_HEIGHT)
	row:SetPoint("RIGHT", parent, "RIGHT", -PANE_INSET, 0)

	row.highlight = T.Tex(row, "BACKGROUND", "post", "list_active")
	row.highlight:SetAllPoints(row)
	row.highlight:SetBlendMode("ADD")
	row.highlight:Hide()
	row.lines = T.Tex(row, "BORDER", "post", "list_borderlines")
	row.lines:SetAllPoints(row)
	row.lines:Hide()
	row.flare = T.Tex(row, "OVERLAY", "post", "list_edgeflare", true)
	row.flare:SetPoint("CENTER", row, "LEFT", 2, 0)
	row.flare:SetBlendMode("ADD")
	row.flare:Hide()
	local hover = T.Tex(row, "HIGHLIGHT", "post", "list_hover")
	hover:SetAllPoints(row)
	hover:SetBlendMode("ADD")

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(24, 24)
	row.icon:SetPoint("LEFT", row, "LEFT", 7, 0)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	row.border = row:CreateTexture(nil, "OVERLAY")
	row.border:SetSize(30, 30)
	row.border:SetPoint("CENTER", row.icon, "CENTER", 0, 0)

	row.price = T.Label(row, "GameFontHighlight")
	row.price:SetPoint("RIGHT", row, "RIGHT", -8, 0)
	row.coin = T.Tex(row, "ARTWORK", "post", "currency")
	row.coin:SetSize(15, 15)
	row.coin:SetPoint("RIGHT", row.price, "LEFT", -4, 0)
	row.mark = row:CreateTexture(nil, "ARTWORK")
	row.mark:SetPoint("RIGHT", row.price, "LEFT", -4, 0)

	row.name = T.Label(row, "GameFontHighlight")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 10, 0)
	row.name:SetPoint("RIGHT", row, "RIGHT", -74, 0)
	row.name:SetJustifyH("LEFT")

	row:SetScript("OnClick", selectRow)
	row:SetScript("OnEnter", showRowTooltip)
	row:SetScript("OnLeave", function () GameTooltip:Hide() end)
	return row
end

-- What fits: a month's goods. A frozen good from another month goes in the slot under them.
local MAX_ROWS = 13

local function buildHeader(top, pad)
	frame.theme = T.Label(frame, "GameFontNormalLarge", nil, 20)
	frame.theme:SetPoint("TOPLEFT", frame, "TOPLEFT", pad + 6, top + 2)
	frame.themeText = T.Label(frame, "GameFontHighlightSmall")
	frame.themeText:SetPoint("TOPLEFT", frame.theme, "BOTTOMLEFT", 0, -3)

	frame.tender = T.Label(frame, "GameFontHighlight", nil, 18)
	frame.tender:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -pad - 6, top)
	local name = T.Label(frame, "GameFontNormalSmall", "Trader's Tender")
	name:SetPoint("TOPRIGHT", frame.tender, "BOTTOMRIGHT", 0, -2)
	local coin = T.Tex(frame, "ARTWORK", "post", "currency")
	coin:SetSize(34, 34)
	coin:SetPoint("BOTTOMRIGHT", name, "BOTTOMLEFT", -6, -1)

	frame.left = T.Label(frame, "GameFontHighlight")
	frame.left:SetPoint("RIGHT", coin, "LEFT", -24, 0)
	local clock = T.Tex(frame, "ARTWORK", "post", "clock", true)
	clock:SetPoint("RIGHT", frame.left, "LEFT", -5, 0)

	local divider = T.Tex(frame, "BORDER", "post", "divider")
	divider:SetHeight(3)
	divider:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, top - 42)
	divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -pad, top - 42)
end

local function buildList(top, pad)
	local pane = CreateFrame("Frame", nil, frame)
	pane:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, top - 48)
	pane:SetWidth(LIST_WIDTH)
	pane:SetHeight(MAX_ROWS * ROW_HEIGHT + PANE_INSET * 2)
	T.NineSlice(pane, "list", 40)
	for index = 1, MAX_ROWS do
		rows[index] = makeRow(pane, index)
		rows[index]:Hide()
	end
	return pane
end

local function buildHold(list, pad)
	local hold = CreateFrame("Button", nil, frame)
	hold:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -2)
	hold:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", pad + LIST_WIDTH, pad)
	T.NineSlice(hold, "hold", 16)
	frame.hold = hold

	hold.selected = T.Tex(hold, "ARTWORK", "post", "list_active")
	hold.selected:SetAllPoints(hold)
	hold.selected:SetBlendMode("ADD")
	hold.selected:Hide()

	local slot = T.Tex(hold, "ARTWORK", "post", "slot_empty")
	slot:SetSize(42, 42)
	slot:SetPoint("LEFT", hold, "LEFT", 10, 0)
	hold.icon = hold:CreateTexture(nil, "OVERLAY", nil, 1)
	hold.icon:SetSize(32, 32)
	hold.icon:SetPoint("CENTER", slot, "CENTER", 0, 0)
	hold.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	hold.ice = T.Tex(hold, "OVERLAY", "post", "frost_frame_1", false, 2)
	hold.ice:SetSize(46, 46)
	hold.ice:SetPoint("CENTER", slot, "CENTER", 0, 0)

	hold.title = T.Label(hold, "GameFontNormal")
	hold.title:SetPoint("TOPLEFT", slot, "TOPRIGHT", 10, -5)
	hold.name = T.Label(hold, "GameFontHighlightSmall")
	hold.name:SetPoint("TOPLEFT", hold.title, "BOTTOMLEFT", 0, -3)
	hold.name:SetPoint("RIGHT", hold, "RIGHT", -8, 0)
	hold.name:SetJustifyH("LEFT")

	hold:SetScript("OnClick", selectRow)
	hold:SetScript("OnEnter", function (self)
		if self.item and self.item ~= 0 then T.ShowItemTooltip(self, self.item) end
	end)
	hold:SetScript("OnLeave", function () GameTooltip:Hide() end)
end

local function buildStage(pad, list)
	local stage = CreateFrame("Frame", nil, frame)
	stage:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
	stage:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad + 42)
	T.NineSlice(stage, "list", 40)

	local inner = PANE_INSET + 2
	local light = T.Tex(stage, "BORDER", "post", "stage_light")
	light:SetPoint("TOPLEFT", stage, "TOPLEFT", inner, -inner)
	light:SetPoint("BOTTOMRIGHT", stage, "BOTTOMRIGHT", -inner, 90)
	light:SetBlendMode("ADD")
	if T.Capital() == "org" then
		light:SetVertexColor(0.6, 0.22, 0.12)
	else
		light:SetVertexColor(0.2, 0.32, 0.55)
	end
	local shadow = T.Tex(stage, "BORDER", "post", "mount_shadow")
	shadow:SetSize(400, 170)
	shadow:SetPoint("CENTER", stage, "BOTTOM", 0, 160)

	frame.model = CreateFrame("PlayerModel", nil, stage)
	frame.model:SetPoint("TOPLEFT", stage, "TOPLEFT", inner, -inner)
	frame.model:SetPoint("BOTTOMRIGHT", stage, "BOTTOMRIGHT", -inner, 90)
	-- A hidden model can drop what it showed, so it loads again when it next shows: the window
	-- opening, or the whole interface coming back from Alt-Z or a cinematic.
	frame.model:SetScript("OnHide", function (self) self.shownEntry = nil end)
	frame.model:SetScript("OnShow", refreshDetail)
	ModelViewLib.Wire(frame.model, 0.5)
	ModelViewLib.AddHint(frame.model)

	-- Frost creeps in from the corners of the stage when the good on it is frozen.
	frame.frost = CreateFrame("Frame", nil, stage)
	frame.frost:SetAllPoints(frame.model)
	frame.frost:SetFrameLevel(frame.model:GetFrameLevel() + 2)
	frame.frost:EnableMouse(false)
	local near = T.Tex(frame.frost, "OVERLAY", "post", "frost_bg")
	near:SetSize(240, 190)
	near:SetPoint("TOPLEFT", frame.model, "TOPLEFT", -6, 6)
	local far = T.Art(frame.frost:CreateTexture(nil, "OVERLAY"), "post", "frost_bg", false, true, true)
	far:SetSize(240, 190)
	far:SetPoint("BOTTOMRIGHT", frame.model, "BOTTOMRIGHT", 6, -6)
	frame.frost:Hide()

	local rule = T.Tex(stage, "BORDER", "post", "divider_short")
	rule:SetHeight(3)
	rule:SetPoint("BOTTOMLEFT", stage, "BOTTOMLEFT", inner, 86)
	rule:SetPoint("BOTTOMRIGHT", stage, "BOTTOMRIGHT", -inner, 86)

	frame.detailPrice = T.Label(stage, "GameFontHighlight", nil, 20)
	frame.detailPrice:SetPoint("TOPRIGHT", rule, "BOTTOMRIGHT", -6, -10)
	frame.detailCoin = T.Tex(stage, "ARTWORK", "post", "currency")
	frame.detailCoin:SetSize(26, 26)
	frame.detailCoin:SetPoint("RIGHT", frame.detailPrice, "LEFT", -6, 0)

	frame.detailName = T.Label(stage, "GameFontNormalLarge", nil, 18)
	frame.detailName:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 6, -8)
	frame.detailName:SetPoint("RIGHT", stage, "RIGHT", -110, 0)
	frame.detailName:SetHeight(22)   -- one line, however long the name: the lines below need the room
	frame.detailName:SetJustifyH("LEFT")
	frame.detailKind = T.Label(stage, "GameFontNormalSmall")
	frame.detailKind:SetPoint("TOPLEFT", frame.detailName, "BOTTOMLEFT", 0, -3)
	frame.detailStatus = T.Label(stage, "GameFontHighlightSmall")
	frame.detailStatus:SetPoint("TOPLEFT", frame.detailKind, "BOTTOMLEFT", 0, -3)
	frame.detailStatus:SetPoint("RIGHT", stage, "RIGHT", -inner - 4, 0)
	frame.detailStatus:SetJustifyH("LEFT")
end

local function buildButtons(pad)
	local left = pad + LIST_WIDTH + 8
	frame.cache = T.CreateButton(frame, "Collector's Cache", 170, 26)
	frame.cache:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", left, pad + 6)
	frame.cache:SetScript("OnClick", function () T.Send("CACHE") end)

	frame.log = T.CreateButton(frame, "Traveler's Log", 110, 26)
	frame.log:SetPoint("LEFT", frame.cache, "RIGHT", 4, 0)
	frame.log:SetScript("OnClick", function () T.OpenLog() end)

	frame.buy = T.CreateButton(frame, "Buy", 110, 32)
	frame.buy:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad - 4, pad + 3)
	frame.buy:SetScript("OnClick", onBuy)

	frame.buyGlow = T.Tex(frame, "ARTWORK", "post", "buybutton_greenglow")
	frame.buyGlow:SetPoint("TOPLEFT", frame.buy, "TOPLEFT", -13, 11)
	frame.buyGlow:SetPoint("BOTTOMRIGHT", frame.buy, "BOTTOMRIGHT", 13, -11)
	frame.buyGlow:SetBlendMode("ADD")
	frame.buyGlow:Hide()

	frame.freeze = T.CreateButton(frame, "Freeze", 76, 26)
	frame.freeze:SetPoint("RIGHT", frame.buy, "LEFT", -8, 0)
	frame.freeze:SetScript("OnClick", onFreeze)
end

local function build()
	frame = CreateFrame("Frame", "TradingPostFrame", UIParent)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:SetToplevel(true)
	frame:SetFrameStrata("HIGH")
	frame:Hide()
	table.insert(UISpecialFrames, "TradingPostFrame")

	local top = T.DressWindow(frame)
	frame.title:SetText("Trading Post")
	T.Stone(frame, T.WindowMargin())

	local pad = T.WindowMargin() + 6
	buildHeader(top, pad)
	local list = buildList(top, pad)
	buildHold(list, pad)
	buildStage(pad, list)
	buildButtons(pad)

	-- The client gets the details of goods it hasn't seen just ahead of the list, but draws no
	-- name until they've landed. The Buy button breathes meanwhile, when it can be pressed.
	local wait, tries, breath = 0, 0, 0
	frame:SetScript("OnUpdate", function (_, elapsed)
		breath = breath + elapsed
		frame.buyGlow:SetAlpha(0.45 + 0.25 * math.sin(breath * 2.5))
		if namesMissing == 0 then
			tries = 0
			return
		end
		wait = wait - elapsed
		if wait > 0 or tries >= 20 then return end
		wait = 0.5
		tries = tries + 1
		refresh()
	end)
end

local function ask()
	T.Send("STATE")
	T.Send("STOCK")
end

T.On("OPEN", function ()
	if not frame then build() end
	selected = nil
	frame:Show()
	ask()
end)

T.On("STATE", refresh)

T.On("STOCK", function ()
	if not selectedGood() then
		local first = T.stock[1]
		selected = first and first.item or nil
	end
	refresh()
end)

T.On("BOUGHT", function (item, success)
	if frame and frame:IsShown() then ask() end
end)

T.On("CACHE", function (success)
	if frame and frame:IsShown() then T.Send("STATE") end
end)

T.On("FROZEN", function ()
	if frame and frame:IsShown() then ask() end
end)

T.On("MONTH", function ()
	if frame and frame:IsShown() then T.Send("STOCK") end
end)

-- Too far from the proprietor: nothing more can be done here until they're spoken to again.
T.On("REFUSED", function (why)
	if frame and frame:IsShown() and why:find("at the Trading Post", 1, true) then frame:Hide() end
end)
