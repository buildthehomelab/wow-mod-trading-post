-- Trading Post: the Traveler's Log. A tab of the Journal when that addon is there, its own window
-- when it isn't. /tlog opens it. Laid out like retail's: the month's bar across the top, filters and
-- the reward on the left, parchment activities on the right.

local T = TradingPost

local ROW_HEIGHT = 64
local COLUMN_WIDTH = 204
local LIST_TOP = -108
local panels = {}

local FILTERS = {
	{ key = "all", name = "All Activities", keep = function () return true end },
	{ key = "open", name = "Still to Do", keep = function (activity) return activity.progress < activity.amount end },
	{ key = "done", name = "Completed", keep = function (activity) return activity.progress >= activity.amount end },
}

local function isDone(activity)
	return activity.progress >= activity.amount
end

-- As retail orders them: under way, then not begun, then finished, the most points first in each.
local function standing(activity)
	if isDone(activity) then return 3 end
	return activity.progress > 0 and 1 or 2
end

local function sorted(filter)
	local list = {}
	for _, activity in ipairs(T.activities) do
		if filter.keep(activity) then list[#list + 1] = activity end
	end
	table.sort(list, function (a, b)
		local left, right = standing(a), standing(b)
		if left ~= right then return left < right end
		if a.points ~= b.points then return a.points > b.points end
		return a.name < b.name
	end)
	return list
end

local function fillRow(row, activity)
	local done = isDone(activity)
	T.SetThreeSlice(row.paper, "log", done and "complete" or "incomplete")
	row.name:SetText(activity.name)
	row.description:SetText(activity.description)
	row.points:SetText(activity.points)
	T.SetShown(row.points, not done)
	T.SetShown(row.check, done)
	T.SetShown(row.bar, not done)
	if done then
		row.name:SetTextColor(0.12, 0.07, 0.02)
		row.description:SetTextColor(0.12, 0.07, 0.02)
		row.name:SetShadowColor(0, 0, 0, 0)
		row.description:SetShadowColor(0, 0, 0, 0)
	else
		row.name:SetTextColor(1, 1, 1)
		row.description:SetTextColor(1, 0.82, 0)
		row.name:SetShadowColor(0, 0, 0, 1)
		row.description:SetShadowColor(0, 0, 0, 1)
		T.SetBar(row.bar, math.min(activity.progress / math.max(activity.amount, 1), 1), "bar_fill")
		row.bar.text:SetText(activity.progress .. " / " .. activity.amount)
	end
	row:Show()
end

local function makeRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row.paper = T.ThreeSlice(row, "BACKGROUND", 28)

	row.ribbon = T.Tex(row, "ARTWORK", "log", "ribbon")
	row.ribbon:SetSize(58, 44)
	row.ribbon:SetPoint("TOPRIGHT", row, "TOPRIGHT", -18, -4)

	row.points = T.Label(row, "GameFontHighlight", nil, 14)
	row.points:SetPoint("CENTER", row.ribbon, "CENTER", 0, 5)

	row.check = T.Tex(row, "OVERLAY", "log", "icon_checkmark", true)
	row.check:SetPoint("CENTER", row.ribbon, "CENTER", 0, 5)

	row.name = T.Label(row, "GameFontHighlight", nil, 14)
	row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 20, -13)
	row.name:SetPoint("RIGHT", row, "RIGHT", -90, 0)
	row.name:SetJustifyH("LEFT")

	row.description = T.Label(row, "GameFontNormal")
	row.description:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
	row.description:SetPoint("RIGHT", row, "RIGHT", -210, 0)
	row.description:SetJustifyH("LEFT")

	row.bar = T.CreateBar(row)
	row.bar:SetSize(112, 14)
	row.bar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -88, 13)
	return row
end

local function refreshFilters(panel)
	for _, button in ipairs(panel.filterButtons) do
		local count = 0
		for _, activity in ipairs(T.activities) do
			if button.filter.keep(activity) then count = count + 1 end
		end
		button.count:SetText(count)
		local chosen = panel.filter == button.filter
		T.SetShown(button.active, chosen)
		if chosen then
			button.name:SetTextColor(1, 1, 1)
		else
			button.name:SetTextColor(1, 0.82, 0)
		end
	end
end

local function milestonesOf(state)
	if #T.milestones > 0 then return T.milestones end
	return { { points = state.needed, tender = state.logPays } }
end

local function nextMilestone(state)
	if state.logDone then return nil end
	for _, milestone in ipairs(milestonesOf(state)) do
		if state.points < milestone.points then return milestone end
	end
	return nil
end

-- A diamond on the bar for each milestone, the last at its right end. Sits by width, which is 0 until
-- the bar has been laid out, so this also runs when its size changes.
local function refreshMarkers(panel)
	local state = T.state
	if not state then return end
	local list = milestonesOf(state)
	local width = panel.total:GetWidth() or 0
	local last = list[#list].points
	for index, milestone in ipairs(list) do
		local marker = panel.markers[index]
		if not marker then
			marker = panel.markerHolder:CreateTexture(nil, "OVERLAY")
			panel.markers[index] = marker
		end
		T.Art(marker, "log", state.points >= milestone.points and "complete_diamond" or "incomplete_diamond", true)
		marker:ClearAllPoints()
		marker:SetPoint("CENTER", panel.total, "LEFT", width * milestone.points / last, 0)
		marker:Show()
	end
	for index = #list + 1, #panel.markers do panel.markers[index]:Hide() end
end

local function refreshReward(panel, state)
	local chest = T.Capital()
	T.Art(panel.chest, "log", "chest_" .. chest, true)
	T.Art(panel.chestGlow, "log", "chest_" .. chest .. "_glow", true)
	T.SetShown(panel.chestGlow, state.logDone)
	local nextUp = nextMilestone(state)
	if nextUp then
		panel.rewardTitle:SetText("Next Reward: " .. nextUp.points .. " Points")
		panel.rewardTender:SetText(nextUp.tender)
	else
		panel.rewardTitle:SetText("|cff33cc33Earned This Month|r")
		panel.rewardTender:SetText(state.logPays)
	end

	if state.bonus ~= 0 then
		panel.bonus.item = state.bonus
		panel.bonus.icon:SetTexture(T.ItemIcon(state.bonus))
		local name = T.ItemName(state.bonus)
		panel.bonus.name:SetText(name and (name .. "\n|cffb0b0b0at " .. state.needed .. " points|r") or "")
		-- The server sends the item's details just ahead of the state, but they can land after it.
		if not name and not panel.bonusWatch:IsShown() then
			panel.bonusWatch.tries = 0
			panel.bonusWatch:Show()
		end
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[T.ItemQuality(state.bonus)]
		if color then panel.bonus.name:SetTextColor(color.r, color.g, color.b) end
		panel.bonus:Show()
	else
		panel.bonus:Hide()
	end
end

local function refresh(panel)
	local state = T.state
	if state then
		panel.theme:SetText(T.theme.name)
		panel.themeText:SetText(T.theme.description)
		panel.left:SetText(T.DaysLeftText())
		panel.tender:SetText(state.balance)
		T.SetBar(panel.total, math.min(state.points / math.max(state.needed, 1), 1), state.logDone and "bar_fill_bonus" or "bar_fill")
		panel.total.value:SetText(state.points .. " / " .. state.needed)
		refreshMarkers(panel)
		refreshReward(panel, state)
	end

	refreshFilters(panel)
	local rows = panel.rows
	local list = sorted(panel.filter)
	for index, activity in ipairs(list) do
		local row = rows[index]
		if not row then
			row = makeRow(panel.list)
			row:SetPoint("TOPLEFT", panel.list, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
			row:SetPoint("RIGHT", panel.list, "RIGHT", 0, 0)
			rows[index] = row
		end
		fillRow(row, activity)
	end
	for index = #list + 1, #rows do rows[index]:Hide() end
	panel.list:SetHeight(math.max(#list * ROW_HEIGHT, 1))
end

local function buildHeader(panel)
	panel.theme = T.Label(panel, "GameFontNormalLarge", nil, 20)
	panel.theme:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -12)
	panel.themeText = T.Label(panel, "GameFontHighlightSmall")
	panel.themeText:SetPoint("TOPLEFT", panel.theme, "BOTTOMLEFT", 0, -3)

	panel.left = T.Label(panel, "GameFontHighlight")
	panel.left:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -20, -14)
	local clock = T.Tex(panel, "ARTWORK", "post", "clock", true)
	clock:SetPoint("RIGHT", panel.left, "LEFT", -5, 0)

	panel.tender = T.Label(panel, "GameFontHighlight", nil, 16)
	panel.tender:SetPoint("RIGHT", clock, "LEFT", -20, 0)
	local coin = T.Tex(panel, "ARTWORK", "post", "currency")
	coin:SetSize(24, 24)
	coin:SetPoint("RIGHT", panel.tender, "LEFT", -5, 0)

	panel.total = T.CreateBar(panel, true)
	panel.total:SetHeight(33)
	panel.total:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, -60)
	panel.total:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -38, -60)
	panel.total.text:ClearAllPoints()
	panel.total.text:SetPoint("LEFT", panel.total, "LEFT", 14, 0)
	panel.total.text:SetText("Points")
	panel.total.value = T.Label(panel.total, "GameFontHighlight")
	panel.total.value:SetPoint("RIGHT", panel.total, "RIGHT", -30, 0)

	panel.markerHolder = CreateFrame("Frame", nil, panel.total)
	panel.markerHolder:SetAllPoints(panel.total)
	panel.markerHolder:SetFrameLevel(panel.total:GetFrameLevel() + 2)
	panel.markers = {}
	panel.total:HookScript("OnSizeChanged", function () refreshMarkers(panel) end)

	local divider = T.Tex(panel, "BORDER", "log", "divider")
	divider:SetHeight(2)
	divider:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, LIST_TOP + 4)
	divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, LIST_TOP + 4)
end

local function buildColumn(panel)
	local column = CreateFrame("Frame", nil, panel)
	column:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, LIST_TOP)
	column:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 8)
	column:SetWidth(COLUMN_WIDTH)
	local back = T.Tex(column, "BACKGROUND", "log", "container")
	back:SetAllPoints(column)

	panel.filterButtons = {}
	for index, filter in ipairs(FILTERS) do
		local button = CreateFrame("Button", nil, column)
		button.filter = filter
		button:SetHeight(26)
		button:SetPoint("TOPLEFT", column, "TOPLEFT", 6, -8 - (index - 1) * 27)
		button:SetPoint("RIGHT", column, "RIGHT", -6, 0)
		button.active = T.Tex(button, "ARTWORK", "post", "list_active")
		button.active:SetAllPoints(button)
		button.active:SetBlendMode("ADD")
		button.active:Hide()
		local hover = T.Tex(button, "HIGHLIGHT", "post", "list_hover")
		hover:SetAllPoints(button)
		hover:SetBlendMode("ADD")
		button.name = T.Label(button, "GameFontNormal", filter.name)
		button.name:SetPoint("LEFT", button, "LEFT", 10, 0)
		button.count = T.Label(button, "GameFontHighlightSmall")
		button.count:SetPoint("RIGHT", button, "RIGHT", -10, 0)
		button:SetScript("OnClick", function ()
			panel.filter = filter
			refresh(panel)
		end)
		panel.filterButtons[index] = button
	end

	-- The reward, under the filters.
	panel.bonus = CreateFrame("Button", nil, column)
	panel.bonus:SetSize(44, 44)
	panel.bonus:SetPoint("BOTTOMLEFT", column, "BOTTOMLEFT", 12, 12)
	panel.bonus.icon = panel.bonus:CreateTexture(nil, "ARTWORK")
	panel.bonus.icon:SetPoint("TOPLEFT", panel.bonus, "TOPLEFT", 4, -4)
	panel.bonus.icon:SetPoint("BOTTOMRIGHT", panel.bonus, "BOTTOMRIGHT", -4, 4)
	panel.bonus.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local frame = T.Tex(panel.bonus, "OVERLAY", "post", "border_square_gold")
	frame:SetAllPoints(panel.bonus)
	panel.bonus.name = T.Label(panel.bonus, "GameFontNormalSmall")
	panel.bonus.name:SetPoint("LEFT", panel.bonus, "RIGHT", 8, 0)
	panel.bonus.name:SetSize(COLUMN_WIDTH - 72, 40)
	panel.bonus.name:SetJustifyH("LEFT")
	panel.bonus:SetScript("OnEnter", function (self)
		if self.item then T.ShowItemTooltip(self, self.item) end
	end)
	panel.bonus:SetScript("OnLeave", function () GameTooltip:Hide() end)
	panel.bonus:Hide()

	panel.bonusWatch = CreateFrame("Frame", nil, column)
	panel.bonusWatch:Hide()
	panel.bonusWatch.wait = 0
	panel.bonusWatch:SetScript("OnUpdate", function (self, elapsed)
		self.wait = self.wait - elapsed
		if self.wait > 0 then return end
		self.wait = 0.5
		self.tries = self.tries + 1
		local item = T.state and T.state.bonus or 0
		local name = item ~= 0 and T.ItemName(item)
		if item == 0 or name or self.tries >= 20 then
			self:Hide()
			if name then refreshReward(panel, T.state) end
		end
	end)

	panel.chestGlow = column:CreateTexture(nil, "ARTWORK", nil, 1)
	panel.chest = column:CreateTexture(nil, "ARTWORK", nil, 2)
	panel.chest:SetPoint("BOTTOMLEFT", panel.bonus, "TOPLEFT", -2, 6)
	panel.chestGlow:SetPoint("CENTER", panel.chest, "CENTER", 0, 0)
	panel.chestGlow:Hide()

	local coin = T.Tex(column, "OVERLAY", "post", "currency")
	coin:SetSize(24, 24)
	coin:SetPoint("LEFT", panel.bonus, "LEFT", 100, 64)
	panel.rewardTender = T.Label(column, "GameFontHighlight", nil, 16)
	panel.rewardTender:SetPoint("LEFT", coin, "RIGHT", 5, 0)

	panel.rewardTitle = T.Label(column, "GameFontNormal")
	panel.rewardTitle:SetPoint("BOTTOMLEFT", panel.chest, "TOPLEFT", 2, 4)
	local rule = T.Tex(column, "BORDER", "post", "divider_short")
	rule:SetHeight(3)
	rule:SetPoint("BOTTOMLEFT", panel.rewardTitle, "TOPLEFT", -4, 6)
	rule:SetWidth(COLUMN_WIDTH - 16)
	return column
end

local scrollCount = 0

local function build(panel)
	panel.rows = {}
	panel.filter = FILTERS[1]
	T.Stone(panel, 0)
	buildHeader(panel)
	local column = buildColumn(panel)

	local rule = T.Tex(panel, "BORDER", "log", "divider_vertical")
	rule:SetWidth(2)
	rule:SetPoint("TOPLEFT", column, "TOPRIGHT", 2, 2)
	rule:SetPoint("BOTTOMLEFT", column, "BOTTOMRIGHT", 2, 0)

	scrollCount = scrollCount + 1
	local scroll = CreateFrame("ScrollFrame", "TradingPostLogScroll" .. scrollCount, panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", column, "TOPRIGHT", 8, 0)
	scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 8)

	panel.list = CreateFrame("Frame", nil, scroll)
	panel.list:SetSize(1, 1)
	scroll:SetScrollChild(panel.list)
	scroll:SetScript("OnSizeChanged", function (self, width)
		panel.list:SetWidth(width)
	end)
	-- A scroll frame reports no size until it has been laid out once.
	scroll:HookScript("OnShow", function (self)
		local width = self:GetWidth()
		if width and width > 0 then panel.list:SetWidth(width) end
	end)

	panels[#panels + 1] = panel
	refresh(panel)
end

local function ask()
	T.Send("STATE")
	T.Send("LOG")
end

local function refreshAll()
	for _, panel in ipairs(panels) do
		if panel:IsVisible() then refresh(panel) end
	end
end

T.On("LOG", refreshAll)
T.On("STATE", refreshAll)

local standalone

local function openStandalone()
	if not standalone then
		standalone = CreateFrame("Frame", "TradingPostLogFrame", UIParent)
		standalone:SetSize(900, 580)
		standalone:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
		standalone:EnableMouse(true)
		standalone:SetMovable(true)
		standalone:SetClampedToScreen(true)
		standalone:SetFrameStrata("HIGH")
		standalone:SetToplevel(true)
		table.insert(UISpecialFrames, "TradingPostLogFrame")
		local top = T.DressWindow(standalone)
		standalone.title:SetText("Traveler's Log")
		local margin = T.WindowMargin()
		local panel = CreateFrame("Frame", nil, standalone)
		panel:SetPoint("TOPLEFT", standalone, "TOPLEFT", margin, top + 8)
		panel:SetPoint("BOTTOMRIGHT", standalone, "BOTTOMRIGHT", -margin, margin)
		build(panel)
		-- The panel's stone would cover the lower part of the stock close button. DragonUI's sits
		-- on its chrome already.
		if not T.Dragon() then standalone.closeButton:SetFrameLevel(panel:GetFrameLevel() + 2) end
		standalone:Hide()
	end
	if standalone:IsShown() then
		standalone:Hide()
	else
		standalone:Show()
		ask()
	end
end

local TAB = "travelerslog"

local function journalAvailable()
	return _G.Journal and _G.Journal.RegisterTab and _G.Journal.OpenTab
end

if journalAvailable() then
	_G.Journal.RegisterTab({
		key = TAB,
		name = "Log",
		order = 28,
		icon = "Interface\\Icons\\INV_Misc_Book_09",
		build = build,
		onShow = ask,
	})
end

-- Raised because this can come from the Trading Post, which is as large as either window, and a
-- toplevel frame is only sure to come to the front when it's clicked.
function T.OpenLog()
	if journalAvailable() and _G.Journal.OpenTab(TAB) then
		if _G.JournalFrame then _G.JournalFrame:Raise() end
		return
	end
	openStandalone()
	if standalone:IsShown() then standalone:Raise() end
end

SLASH_TRADINGPOSTLOG1 = "/tlog"
SLASH_TRADINGPOSTLOG2 = "/travelerslog"
SlashCmdList["TRADINGPOSTLOG"] = function ()
	T.OpenLog()
end
