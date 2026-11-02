-- Trading Post widgets: the window's border is stock, or DragonUI's when it's loaded. What's inside
-- it is drawn with retail's own Trading Post art, packed into Art/ by tools/build_art.py.

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

-- How far in from the window's edge its border ends.
function T.WindowMargin()
	return T.Dragon() and 3 or 11
end

local ART_DIR = "Interface\\AddOns\\TradingPost\\Art\\"
local ART_SIZE = 1024

-- Puts a piece of the art on a texture. sized gives it retail's size for the piece.
function T.Art(texture, sheet, piece, sized, flipH, flipV)
	local p = T.ArtData[sheet][piece]
	local left, right = p[1] / ART_SIZE, (p[1] + p[3]) / ART_SIZE
	local top, bottom = p[2] / ART_SIZE, (p[2] + p[4]) / ART_SIZE
	if flipH then left, right = right, left end
	if flipV then top, bottom = bottom, top end
	texture:SetTexture(ART_DIR .. sheet)
	texture:SetTexCoord(left, right, top, bottom)
	if sized then texture:SetSize(p[5], p[6]) end
	return texture
end

function T.Tex(parent, layer, sheet, piece, sized, sublevel)
	return T.Art(parent:CreateTexture(nil, layer, nil, sublevel), sheet, piece, sized)
end

-- Fills a window's or a tab's area with the dark stone retail's log sits on, without the piece's
-- header band: where that band's rule fell would depend on the area's height.
local STONE_BAND = 58

function T.Stone(frame, inset)
	local stone = T.Tex(frame, "BACKGROUND", "log", "background", false, -6)
	local p = T.ArtData.log.background
	stone:SetTexCoord(p[1] / ART_SIZE, (p[1] + p[3]) / ART_SIZE, (p[2] + STONE_BAND) / ART_SIZE, (p[2] + p[4]) / ART_SIZE)
	stone:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, inset == 0 and 0 or (T.Dragon() and -21 or -inset))
	stone:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
	return stone
end

-- A piece stretched sideways with its ends left alone, so a row's border stays one width.
function T.ThreeSlice(parent, layer, cap)
	local slice = {
		cap = cap,
		left = parent:CreateTexture(nil, layer),
		middle = parent:CreateTexture(nil, layer),
		right = parent:CreateTexture(nil, layer),
	}
	slice.left:SetWidth(cap)
	slice.left:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	slice.left:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
	slice.right:SetWidth(cap)
	slice.right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
	slice.right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
	slice.middle:SetPoint("TOPLEFT", slice.left, "TOPRIGHT", 0, 0)
	slice.middle:SetPoint("BOTTOMRIGHT", slice.right, "BOTTOMLEFT", 0, 0)
	return slice
end

function T.SetThreeSlice(slice, sheet, piece)
	local p = T.ArtData[sheet][piece]
	local left, right = p[1] / ART_SIZE, (p[1] + p[3]) / ART_SIZE
	local top, bottom = p[2] / ART_SIZE, (p[2] + p[4]) / ART_SIZE
	local cap = slice.cap / ART_SIZE
	for _, part in ipairs({ slice.left, slice.middle, slice.right }) do
		part:SetTexture(ART_DIR .. sheet)
	end
	slice.left:SetTexCoord(left, left + cap, top, bottom)
	slice.middle:SetTexCoord(left + cap, right - cap, top, bottom)
	slice.right:SetTexCoord(right - cap, right, top, bottom)
end

-- Retail's framed panes. "list" has one corner, mirrored; "hold" has all four.
function T.NineSlice(frame, name, size)
	local corner = name .. "_nineslice_corner"
	local one = not T.ArtData.post[corner .. "bottomleft"]
	local function piece(layer, part, flipH, flipV)
		local tex = frame:CreateTexture(nil, layer)
		T.Art(tex, "post", name .. "_nineslice_" .. part, false, flipH, flipV)
		return tex
	end
	local function cornerAt(where, part, flipH, flipV)
		local tex = one and piece("BORDER", "cornertopleft", flipH, flipV) or piece("BORDER", part)
		tex:SetSize(size, size)
		tex:SetPoint(where, frame, where, 0, 0)
		return tex
	end
	local tl = cornerAt("TOPLEFT", "cornertopleft", false, false)
	local tr = cornerAt("TOPRIGHT", "cornertopright", true, false)
	local bl = cornerAt("BOTTOMLEFT", "cornerbottomleft", false, true)
	local br = cornerAt("BOTTOMRIGHT", "cornerbottomright", true, true)

	local top = piece("BORDER", "edgetop")
	top:SetPoint("TOPLEFT", tl, "TOPRIGHT", 0, 0)
	top:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT", 0, 0)
	local bottom = piece("BORDER", "edgetop", false, true)
	bottom:SetPoint("TOPLEFT", bl, "TOPRIGHT", 0, 0)
	bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT", 0, 0)
	local left = piece("BORDER", "edgeleft")
	left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT", 0, 0)
	left:SetPoint("BOTTOMRIGHT", bl, "TOPRIGHT", 0, 0)
	local right = piece("BORDER", "edgeleft", true)
	right:SetPoint("TOPLEFT", tr, "BOTTOMLEFT", 0, 0)
	right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT", 0, 0)
	local center = piece("BACKGROUND", "center")
	center:SetPoint("TOPLEFT", tl, "BOTTOMRIGHT", 0, 0)
	center:SetPoint("BOTTOMRIGHT", br, "TOPLEFT", 0, 0)
	return center
end

-- A progress bar with retail's art. The fill is a plain texture, cut to length here: a status bar
-- rewrites its texture's coordinates, and this one is a piece of a larger sheet.
function T.CreateBar(parent, border)
	local bar = CreateFrame("Frame", nil, parent)
	bar.back = T.Tex(bar, "BACKGROUND", "log", "bar_background")
	bar.back:SetAllPoints(bar)
	bar.fill = bar:CreateTexture(nil, "ARTWORK")
	bar.fill:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
	bar.fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 1, 1)
	if border then
		local line = T.Tex(bar, "OVERLAY", "log", "bar_border")
		line:SetPoint("TOPLEFT", bar, "TOPLEFT", -6, 5)
		line:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 7, -9)
	end
	bar.text = T.Label(bar, "GameFontHighlightSmall")
	bar.text:SetPoint("CENTER", bar, "CENTER", 0, 0)
	bar:SetScript("OnSizeChanged", function (self)
		if self.fraction then T.SetBar(self, self.fraction, self.piece) end
	end)
	return bar
end

function T.SetBar(bar, fraction, piece)
	bar.fraction, bar.piece = fraction, piece
	local width = (bar:GetWidth() or 0) - 2
	if fraction <= 0 or width <= 0 then
		bar.fill:Hide()
		return
	end
	local p = T.ArtData.log[piece]
	T.Art(bar.fill, "log", piece)
	bar.fill:SetTexCoord(p[1] / ART_SIZE, (p[1] + p[3] * fraction) / ART_SIZE, p[2] / ART_SIZE, (p[2] + p[4]) / ART_SIZE)
	bar.fill:SetWidth(math.max(1, width * fraction))
	bar.fill:Show()
end

-- Retail's chest and list colours follow the player's capital.
function T.Capital()
	return UnitFactionGroup("player") == "Horde" and "org" or "sw"
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

function T.Label(parent, font, text, size)
	local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
	if text then label:SetText(text) end
	if size then
		local path, _, flags = label:GetFont()
		label:SetFont(path, size, flags)
	end
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
