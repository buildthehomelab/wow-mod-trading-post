-- Trading Post: the Traveler's Log. A tab of the Journal when that addon is there, its own window
-- when it isn't. /tlog opens it.

local T = TradingPost

local ROW_HEIGHT = 40
local panels = {}

local function fillRow(row, activity)
	local done = activity.progress >= activity.amount
	row.name:SetText(activity.name)
	row.description:SetText(activity.description)
	row.points:SetText(activity.points .. " points")
	row.bar:SetMinMaxValues(0, activity.amount)
	row.bar:SetValue(math.min(activity.progress, activity.amount))
	row.bar.text:SetText(activity.progress .. " / " .. activity.amount)
	if done then
		row.bar:SetStatusBarColor(0.1, 0.7, 0.1)
		row.name:SetTextColor(0.6, 0.6, 0.6)
		row.check:Show()
	else
		row.bar:SetStatusBarColor(0.9, 0.7, 0.1)
		row.name:SetTextColor(1, 0.82, 0)
		row.check:Hide()
	end
	row:Show()
end

local function makeRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(ROW_HEIGHT)

	row.check = row:CreateTexture(nil, "OVERLAY")
	row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
	row.check:SetSize(20, 20)
	row.check:SetPoint("LEFT", row, "LEFT", 2, 0)

	row.name = T.Label(row, "GameFontNormal")
	row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 24, -3)

	row.description = T.Label(row, "GameFontHighlightSmall")
	row.description:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)

	row.points = T.Label(row, "GameFontHighlightSmall")
	row.points:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -4)

	row.bar = CreateFrame("StatusBar", nil, row)
	row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	row.bar:SetSize(110, 13)
	row.bar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 5)
	local back = row.bar:CreateTexture(nil, "BACKGROUND")
	back:SetAllPoints(row.bar)
	back:SetTexture(0, 0, 0, 0.5)
	row.bar.text = T.Label(row.bar, "GameFontHighlightSmall")
	row.bar.text:SetPoint("CENTER", row.bar, "CENTER", 0, 0)

	return row
end

local function refresh(panel)
	local state = T.state
	if state then
		panel.theme:SetText(T.theme.name)
		panel.left:SetText(T.DaysLeftText())
		panel.total:SetMinMaxValues(0, state.needed)
		panel.total:SetValue(math.min(state.points, state.needed))
		panel.total.text:SetText(state.points .. " / " .. state.needed .. " points")
		panel.reward:SetText(state.logDone and "Complete: reward earned." or
			("Complete it for " .. state.logPays .. " Trader's Tender and:"))
		panel.tender:SetText("Trader's Tender: " .. state.balance)

		if state.bonus ~= 0 then
			panel.bonus.item = state.bonus
			panel.bonus.icon:SetTexture(T.ItemIcon(state.bonus))
			panel.bonus:Show()
		else
			panel.bonus:Hide()
		end
	end

	local rows = panel.rows
	for index, activity in ipairs(T.activities) do
		local row = rows[index]
		if not row then
			row = makeRow(panel.list)
			row:SetPoint("TOPLEFT", panel.list, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
			row:SetPoint("RIGHT", panel.list, "RIGHT", 0, 0)
			rows[index] = row
		end
		fillRow(row, activity)
	end
	for index = #T.activities + 1, #rows do rows[index]:Hide() end
	panel.list:SetHeight(math.max(#T.activities * ROW_HEIGHT, 1))
end

local scrollCount = 0

local function build(panel)
	panel.rows = {}

	local header = T.CreateInset(panel)
	header:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	header:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
	header:SetHeight(74)

	panel.theme = T.Label(header, "GameFontNormalLarge")
	panel.theme:SetPoint("TOPLEFT", header, "TOPLEFT", 12, -10)

	panel.left = T.Label(header, "GameFontHighlightSmall")
	panel.left:SetPoint("LEFT", panel.theme, "RIGHT", 10, 0)

	panel.tender = T.Label(header, "GameFontHighlightSmall")
	panel.tender:SetPoint("TOPRIGHT", header, "TOPRIGHT", -12, -12)

	panel.total = CreateFrame("StatusBar", nil, header)
	panel.total:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	panel.total:SetStatusBarColor(0.9, 0.7, 0.1)
	panel.total:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 12, 12)
	panel.total:SetSize(220, 18)
	local back = panel.total:CreateTexture(nil, "BACKGROUND")
	back:SetAllPoints(panel.total)
	back:SetTexture(0, 0, 0, 0.5)
	panel.total.text = T.Label(panel.total, "GameFontHighlightSmall")
	panel.total.text:SetPoint("CENTER", panel.total, "CENTER", 0, 0)

	panel.bonus = CreateFrame("Button", nil, header)
	panel.bonus:SetSize(34, 34)
	panel.bonus:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", -12, 10)
	panel.bonus.icon = panel.bonus:CreateTexture(nil, "ARTWORK")
	panel.bonus.icon:SetAllPoints(panel.bonus)
	panel.bonus:SetScript("OnEnter", function (self)
		if self.item then T.ShowItemTooltip(self, self.item) end
	end)
	panel.bonus:SetScript("OnLeave", function () GameTooltip:Hide() end)
	panel.bonus:Hide()

	panel.reward = T.Label(header, "GameFontHighlightSmall")
	panel.reward:SetPoint("RIGHT", panel.bonus, "LEFT", -8, 0)

	local pane = T.CreateInset(panel)
	pane:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
	pane:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

	scrollCount = scrollCount + 1
	local scroll = CreateFrame("ScrollFrame", "TradingPostLogScroll" .. scrollCount, pane, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", pane, "TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -28, 8)

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
		standalone:SetSize(560, 520)
		standalone:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
		standalone:EnableMouse(true)
		standalone:SetMovable(true)
		standalone:SetClampedToScreen(true)
		standalone:SetFrameStrata("HIGH")
		standalone:SetToplevel(true)
		table.insert(UISpecialFrames, "TradingPostLogFrame")
		local top = T.DressWindow(standalone)
		standalone.title:SetText("Traveler's Log")
		local panel = CreateFrame("Frame", nil, standalone)
		panel:SetPoint("TOPLEFT", standalone, "TOPLEFT", 16, top)
		panel:SetPoint("BOTTOMRIGHT", standalone, "BOTTOMRIGHT", -16, 16)
		build(panel)
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

function T.OpenLog()
	if journalAvailable() and _G.Journal.OpenTab(TAB) then return end
	openStandalone()
end

SLASH_TRADINGPOSTLOG1 = "/tlog"
SLASH_TRADINGPOSTLOG2 = "/travelerslog"
SlashCmdList["TRADINGPOSTLOG"] = function ()
	T.OpenLog()
end
