-- Trading Post: the proprietor's window. Opens when the server says so, after talking to one. The
-- month's goods on the left, the chosen one turning on the right.

local T = TradingPost

local WIDTH, HEIGHT = 680, 520
local ROW_HEIGHT = 26

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

local function statusLine(good)
	if good.status == T.STATUS_OWNED then return "|cff33cc33You own this.|r" end
	if good.status == T.STATUS_LOCKED then return "|cffff8040" .. good.unlock .. "|r" end
	if good.status == T.STATUS_SELF_FOUND then return "|cffff8040Self-Found characters can't buy from the Trading Post.|r" end
	if good.frozen then return "|cff66ccffFrozen: it stays on sale for you until you buy it.|r" end
	return ""
end

local function refreshDetail()
	local good = selectedGood()
	if not good then
		T.ShowCreature(frame.model, nil)
		frame.detailName:SetText("")
		frame.detailPrice:SetText("")
		frame.detailStatus:SetText("")
		T.SetEnabled(frame.buy, false)
		T.SetEnabled(frame.freeze, false)
		frame.freeze:SetText("Freeze")
		return
	end

	T.ShowCreature(frame.model, good.creature)
	frame.detailName:SetText(goodNamed(good.item))
	frame.detailPrice:SetText(good.price .. " Trader's Tender")
	frame.detailStatus:SetText(statusLine(good))

	local forSale = good.status == T.STATUS_FOR_SALE
	local balance = T.state and T.state.balance or 0
	T.SetEnabled(frame.buy, forSale and balance >= good.price)
	T.SetEnabled(frame.freeze, forSale)
	frame.freeze:SetText(good.frozen and "Thaw" or "Freeze")
end

local function refreshList()
	namesMissing = 0
	for index, good in ipairs(T.stock) do
		local row = rows[index]
		if not row then break end
		row.good = good
		row.icon:SetTexture(T.ItemIcon(good.item))
		local name = T.ItemName(good.item)
		if not name then namesMissing = namesMissing + 1 end
		row.name:SetText(name or ("Item " .. good.item))
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[T.ItemQuality(good.item)]
		if color then row.name:SetTextColor(color.r, color.g, color.b) end

		if good.status == T.STATUS_OWNED then
			row.price:SetText("Owned")
		elseif good.status == T.STATUS_LOCKED then
			row.price:SetText("Locked")
		else
			row.price:SetText(good.price)
		end
		T.SetShown(row.frozen, good.frozen)
		T.SetShown(row.highlight, good.item == selected)
		row:Show()
	end
	for index = #T.stock + 1, #rows do rows[index]:Hide() end
end

local function refreshHeader()
	local state = T.state
	if not state then return end
	frame.theme:SetText(T.theme.name)
	frame.themeText:SetText(T.theme.description)
	frame.left:SetText(T.DaysLeftText())
	frame.tender:SetText("Trader's Tender: |cffffffff" .. state.balance .. "|r")
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

local function makeRow(parent, index)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -8 - (index - 1) * ROW_HEIGHT)
	row:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

	row.highlight = row:CreateTexture(nil, "BACKGROUND")
	row.highlight:SetAllPoints(row)
	row.highlight:SetTexture(1, 0.82, 0, 0.18)
	row.highlight:Hide()

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(22, 22)
	row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)

	row.name = T.Label(row, "GameFontHighlight")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.name:SetPoint("RIGHT", row, "RIGHT", -74, 0)
	row.name:SetJustifyH("LEFT")

	row.price = T.Label(row, "GameFontHighlightSmall")
	row.price:SetPoint("RIGHT", row, "RIGHT", -6, 0)

	row.frozen = row:CreateTexture(nil, "OVERLAY")
	row.frozen:SetTexture("Interface\\Icons\\Spell_Frost_FrostBolt02")
	row.frozen:SetSize(14, 14)
	row.frozen:SetPoint("RIGHT", row.price, "LEFT", -4, 0)
	row.frozen:Hide()

	row:SetScript("OnClick", function (self)
		if self.good then
			selected = self.good.item
			refresh()
		end
	end)
	row:SetScript("OnEnter", function (self)
		if self.good then T.ShowItemTooltip(self, self.good.item) end
	end)
	row:SetScript("OnLeave", function () GameTooltip:Hide() end)
	return row
end

-- What fits: a month's goods plus a frozen item from another month.
local MAX_ROWS = 14

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

	frame.theme = T.Label(frame, "GameFontNormalLarge")
	frame.theme:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, top - 2)
	frame.left = T.Label(frame, "GameFontHighlightSmall")
	frame.left:SetPoint("LEFT", frame.theme, "RIGHT", 10, 0)
	frame.tender = T.Label(frame, "GameFontNormal")
	frame.tender:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, top - 4)
	frame.themeText = T.Label(frame, "GameFontHighlightSmall")
	frame.themeText:SetPoint("TOPLEFT", frame.theme, "BOTTOMLEFT", 0, -3)

	local bottom = 16
	local listPane = T.CreateInset(frame)
	listPane:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, top - 44)
	listPane:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, bottom + 30)
	listPane:SetWidth(310)
	for index = 1, MAX_ROWS do
		rows[index] = makeRow(listPane, index)
		rows[index]:Hide()
	end

	frame.cache = T.CreateButton(frame, "Collector's Cache", 180)
	frame.cache:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, bottom)
	frame.cache:SetScript("OnClick", function () T.Send("CACHE") end)

	frame.log = T.CreateButton(frame, "Traveler's Log", 124)
	frame.log:SetPoint("LEFT", frame.cache, "RIGHT", 6, 0)
	frame.log:SetScript("OnClick", function () T.OpenLog() end)

	local stage = T.CreateInset(frame)
	stage:SetPoint("TOPLEFT", listPane, "TOPRIGHT", 8, 0)
	stage:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, bottom + 30)

	frame.model = CreateFrame("PlayerModel", nil, stage)
	frame.model:SetPoint("TOPLEFT", stage, "TOPLEFT", 6, -6)
	frame.model:SetPoint("BOTTOMRIGHT", stage, "BOTTOMRIGHT", -6, 76)
	frame.model:EnableMouse(true)
	frame.model.facing = 0.5
	frame.model:SetScript("OnMouseDown", function (self) self.turning = GetCursorPosition() end)
	frame.model:SetScript("OnMouseUp", function (self) self.turning = nil end)
	frame.model:SetScript("OnUpdate", function (self)
		if not self.turning then return end
		local x = GetCursorPosition()
		self.facing = (self.facing or 0) + (x - self.turning) * 0.012
		self.turning = x
		self:SetFacing(self.facing)
	end)

	frame.detailName = T.Label(stage, "GameFontNormal")
	frame.detailName:SetPoint("TOPLEFT", frame.model, "BOTTOMLEFT", 4, -6)
	frame.detailName:SetPoint("RIGHT", stage, "RIGHT", -10, 0)
	frame.detailName:SetJustifyH("LEFT")
	frame.detailPrice = T.Label(stage, "GameFontHighlightSmall")
	frame.detailPrice:SetPoint("TOPLEFT", frame.detailName, "BOTTOMLEFT", 0, -3)
	frame.detailStatus = T.Label(stage, "GameFontHighlightSmall")
	frame.detailStatus:SetPoint("TOPLEFT", frame.detailPrice, "BOTTOMLEFT", 0, -3)
	frame.detailStatus:SetPoint("RIGHT", stage, "RIGHT", -10, 0)
	frame.detailStatus:SetJustifyH("LEFT")
	frame.detailStatus:SetHeight(24)

	frame.buy = T.CreateButton(frame, "Buy", 100)
	frame.buy:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, bottom)
	frame.buy:SetScript("OnClick", onBuy)

	frame.freeze = T.CreateButton(frame, "Freeze", 100)
	frame.freeze:SetPoint("RIGHT", frame.buy, "LEFT", -6, 0)
	frame.freeze:SetScript("OnClick", onFreeze)

	-- The client gets the details of goods it hasn't seen just ahead of the list, but draws no
	-- name until they've landed.
	local wait, tries = 0, 0
	frame:SetScript("OnUpdate", function (_, elapsed)
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
