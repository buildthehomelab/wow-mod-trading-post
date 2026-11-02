-- Trading Post widgets: stock Blizzard frames, dressed in DragonUI's retail art when it's loaded.

local T = TradingPost

-- DragonUI_NineSlice since DragonUI's 2026 rewrite, NineSliceUtils before it.
local NineSlice = _G.DragonUI_NineSlice or _G.NineSliceUtils

function T.Dragon()
	local D = _G.DragonUI
	if D and D._dir and D.atlasinfo and D.SafeSetAtlas and D.SkinRedButton and NineSlice
			and D.CharacterPanel and D.CharacterPanel.ReskinTab then
		return D, D.CharacterPanel
	end
end

local DIALOG_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 32,
	insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

local BOX_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 5, right = 5, top = 5, bottom = 5 },
}

local function tiled(host, sublevel, file)
	local tex = host:CreateTexture(nil, "BACKGROUND", nil, sublevel)
	tex:SetTexture(file, "REPEAT", "REPEAT")
	tex:SetHorizTile(true)
	tex:SetVertTile(true)
	return tex
end

-- Gives a window its look, a title (frame.title), a close button and a bar to drag it by. Returns
-- the y offset its content starts at.
function T.DressWindow(frame)
	local D, CP = T.Dragon()
	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	frame.closeButton = close

	if D then
		local rock = tiled(frame, -8, D._dir .. "UI\\ui-background-rock")
		rock:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -21)
		rock:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)

		-- On its own frame above the content, so no child panel draws over the metal.
		local chrome = CreateFrame("Frame", nil, frame)
		chrome:SetAllPoints(frame)
		chrome:SetFrameLevel(frame:GetFrameLevel() + 30)
		chrome:EnableMouse(false)
		NineSlice.ApplyLayout(chrome, NineSlice.GetLayout("NoPortraitFrameTemplate") or NineSlice.GetLayout("PortraitFrameTemplate"))

		frame.title = chrome:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		frame.title:SetPoint("TOP", frame, "TOP", 0, -5)
		close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)
		if CP.ModernizeCloseButton then
			CP.ModernizeCloseButton(close, chrome, 1, 0)
			close:SetFrameLevel(chrome:GetFrameLevel() + 5)
		end
	else
		frame:SetBackdrop(DIALOG_BACKDROP)
		local header = frame:CreateTexture(nil, "ARTWORK")
		header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
		header:SetSize(320, 64)
		header:SetPoint("TOP", frame, "TOP", 0, 12)
		frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		frame.title:SetPoint("TOP", header, "TOP", 0, -14)
		close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
	end

	local bar = CreateFrame("Frame", nil, frame)
	bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, D and 0 or 12)
	bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, 0)
	bar:SetHeight(D and 24 or 36)
	bar:EnableMouse(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", function () frame:StartMoving() end)
	bar:SetScript("OnDragStop", function () frame:StopMovingOrSizing() end)

	return D and -30 or -34
end

-- A recessed pane: retail's InsetFrameTemplate with DragonUI, the stock options box without.
function T.CreateInset(parent)
	local pane = CreateFrame("Frame", nil, parent)
	local D = T.Dragon()
	if D then
		local bg = tiled(pane, -5, D._dir .. "UI\\ui-background-marble")
		bg:SetAllPoints(pane)
		NineSlice.ApplyLayout(pane, NineSlice.GetLayout("InsetFrameTemplate"))
	else
		pane:SetBackdrop(BOX_BACKDROP)
		pane:SetBackdropColor(0.1, 0.1, 0.1, 1)
		pane:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
	end
	return pane
end

local buttonCount = 0

function T.CreateButton(parent, text, width, height)
	buttonCount = buttonCount + 1
	local button = CreateFrame("Button", "TradingPostButton" .. buttonCount, parent, "UIPanelButtonTemplate")
	button:SetSize(width, height or 22)
	button:SetText(text)
	local D = T.Dragon()
	if D then D.SkinRedButton(button) end
	return button
end

function T.SetEnabled(control, enabled)
	if enabled then control:Enable() else control:Disable() end
end

function T.SetShown(region, shown)
	if shown then region:Show() else region:Hide() end
end

function T.Label(parent, font, text)
	local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
	if text then label:SetText(text) end
	return label
end

-- Creature previews. A 3.3.5 model frame only draws creatures the client already has a record of,
-- and asks for none, so the server is asked to send it and the model is set again until it draws.
local RETRY, MAX_TRIES = 0.5, 12
local asked = {}
local pending = {}
local loader = CreateFrame("Frame")
loader:Hide()
loader.wait = 0

local function drawn(model)
	local file = model.GetModel and model:GetModel()
	return type(file) == "string" and file ~= ""
end

loader:SetScript("OnUpdate", function (self, elapsed)
	self.wait = self.wait - elapsed
	if self.wait > 0 then return end
	self.wait = RETRY
	local any = false
	for model in pairs(pending) do
		model.tries = (model.tries or 0) + 1
		if drawn(model) or model.tries > MAX_TRIES or not model:IsVisible() or not model.shownEntry then
			if drawn(model) and model.shownEntry then ModelViewLib.Frame(model, model.shownEntry) end
			pending[model] = nil
		else
			model:SetCreature(model.shownEntry)
			any = true
		end
	end
	if not any then self:Hide() end
end)

function T.ShowCreature(model, entry)
	-- A reply can land while the interface is hidden: the model's OnShow comes back for it.
	if not model:IsVisible() then
		model.shownEntry = nil
		pending[model] = nil
		return
	end
	if not entry or entry == 0 then
		ModelViewLib.BeforeLoad(model)
		model:ClearModel()
		model.shownEntry = nil
		pending[model] = nil
		return
	end
	if model.shownEntry == entry then return end
	model.shownEntry = entry
	model.tries = 0
	ModelViewLib.BeforeLoad(model)
	model:ClearModel()
	model:SetCreature(entry)
	if drawn(model) then
		ModelViewLib.Frame(model, entry)
		pending[model] = nil
	else
		if not asked[entry] then
			asked[entry] = true
			T.Send("R:" .. entry)
		end
		pending[model] = true
		loader:Show()
	end
end
