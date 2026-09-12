-- Delve Enemy Counter
--
-- Inside a Delve, the tracker shows affixes such as Nemesis Influence as UI
-- widget icons whose only readable state is a mouse-over tooltip like
-- "Enemy groups remaining: 1 / 4". Those are enemy groups, not individual
-- enemies: the count drops by one when a whole pack is cleared.
--
-- Hover is the only way the game offers that number, which puts it out of
-- reach of anyone not playing with a mouse. This addon puts it on screen and
-- leaves it there, so no pointer is needed to read it. Nothing happens
-- outside Delves.
--
-- How it works: each widget frame carries widgetID and widgetType; the
-- widget's data comes from the type's visualization-info function
-- (registered in Blizzard's UIWidgetManager), and the tooltip mixin also
-- keeps the text on the frame or one of its children. Whichever yields
-- "n / m", n is what we show.
--
-- Where it goes: the Delves header widget already draws its lives remaining
-- as an icon and a number, so the count joins that row rather than sitting
-- on top of an affix icon. Anywhere else, it falls back to painting over
-- the icon.

local addonName, ns = ...

local ADDON_TITLE = "Delve Enemy Counter"
-- "Delves" difficulty; read from the client when it exposes it, 208 otherwise
-- (warcraft.wiki.gg/wiki/DifficultyID).
local DELVE_DIFFICULTY_ID = (DifficultyUtil and DifficultyUtil.ID and DifficultyUtil.ID.Delves) or 208
-- Widget events come in bursts; coalesce them into one scan.
local SCAN_DELAY = 0.5

local DEFAULTS = {
    enabled = true,  -- master switch
    icon = "skull",  -- a name from ICONS below, or a texture path
    iconScale = 0.8, -- fraction of the neighbouring currency icon's size
    iconGap = 5,     -- pixels between the icon and the count
}

local db
-- Widget frame -> our overlay font string (weak keys: frames may be released).
local overlays = setmetatable({}, { __mode = "k" })
-- Currency container -> our badge frame, same weak keys for the same reason.
local badges = setmetatable({}, { __mode = "k" })
local scanPending = false

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. ADDON_TITLE .. ":|r " .. msg)
end

local function InDelve()
    local _, _, difficultyID = GetInstanceInfo()
    return difficultyID == DELVE_DIFFICULTY_ID
end

-- ------------------------------------------------------------ reading widgets

local function TooltipRemaining(tooltip)
    if type(tooltip) ~= "string" then
        return nil
    end
    local last
    for n in tooltip:gmatch("(%d+)%s*/%s*%d+") do
        last = n
    end
    return last
end

-- First "n / m" found in any string inside a (nested) table, depth-limited.
local function RatioInTable(t, depth)
    if type(t) ~= "table" or depth > 3 then
        return nil
    end
    for _, v in pairs(t) do
        if type(v) == "string" then
            local n = TooltipRemaining(v)
            if n then
                return n, v
            end
        elseif type(v) == "table" then
            local n, text = RatioInTable(v, depth + 1)
            if n then
                return n, text
            end
        end
    end
    return nil
end

local function WidgetInfo(frame)
    local registry = UIWidgetManager and UIWidgetManager.widgetVisTypeInfo
    local typeInfo = registry and registry[frame.widgetType]
    if typeInfo and type(typeInfo.visInfoDataFunction) == "function" then
        local ok, info = pcall(typeInfo.visInfoDataFunction, frame.widgetID)
        if ok then
            return info
        end
    end
    return nil
end

-- Every tooltip string the tooltip mixin keeps on the frame or any
-- descendant (the Delves header widget holds its affix icons as children,
-- each with its own tooltip).
local function FrameTooltips(frame, depth, out)
    out = out or {}
    if type(frame.tooltip) == "string" and frame.tooltip ~= "" then
        out[#out + 1] = frame.tooltip
    end
    if depth < 5 and frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            FrameTooltips(child, depth + 1, out)
        end
    end
    return out
end

-- Descendant frame set up for this spell (UIWidgetBaseSpellTemplate keeps
-- spellID on itself), so the number can sit on the right icon.
local function SpellChild(frame, spellID, depth)
    if frame.spellID == spellID then
        return frame
    end
    if depth < 5 and frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            local found = SpellChild(child, spellID, depth + 1)
            if found then
                return found
            end
        end
    end
    return nil
end

local function SpellDescription(spellID)
    if C_Spell and C_Spell.GetSpellDescription then
        return C_Spell.GetSpellDescription(spellID)
    end
    return nil
end

-- Returns the remaining count, the text it came from, and the frame to
-- paint on (the affix icon when it can be found, else the widget), or nil.
-- Sources, in order: the widget's own data, its affix spells' live
-- descriptions, and any tooltip text kept on the frame or its descendants.
local function WidgetRemaining(frame)
    local info = WidgetInfo(frame)
    local n, text = RatioInTable(info, 0)
    if n then
        return n, text, frame
    end
    if info and type(info.spells) == "table" then
        for _, spell in ipairs(info.spells) do
            local description = spell.spellID and SpellDescription(spell.spellID)
            n = TooltipRemaining(description)
            if n then
                return n, description, SpellChild(frame, spell.spellID, 0) or frame
            end
        end
    end
    for _, tooltip in ipairs(FrameTooltips(frame, 0)) do
        n = TooltipRemaining(tooltip)
        if n then
            return n, tooltip, frame
        end
    end
    return nil
end

-- Every live UI widget frame, from the widget manager's registry of widget
-- containers (each container keeps widgetFrames[widgetID]). Never
-- EnumerateFrames: with a busy UI that exceeds the script time limit.
local function CollectContainers(t, depth, out)
    if type(t) ~= "table" or depth > 2 then
        return
    end
    if type(t.widgetFrames) == "table" then
        out[t] = true
        return
    end
    for k, v in pairs(t) do
        if type(k) == "table" and type(k.widgetFrames) == "table" then
            out[k] = true
        elseif type(v) == "table" then
            CollectContainers(v, depth + 1, out)
        end
    end
end

local function WidgetFrames()
    local list = {}
    local registry = UIWidgetManager and UIWidgetManager.registeredWidgetContainers
    local containers = {}
    CollectContainers(registry, 0, containers)
    for container in pairs(containers) do
        for _, frame in pairs(container.widgetFrames) do
            if type(frame) == "table" and frame.widgetID and frame.widgetType then
                list[#list + 1] = frame
            end
        end
    end
    return list
end

-- ------------------------------------------------------------------ overlays

local function OverlayFor(frame)
    local text = overlays[frame]
    if not text then
        text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        text:SetPoint("CENTER", frame, "CENTER", 0, 0)
        text:SetTextColor(1, 1, 1)
        text:SetShadowColor(0, 0, 0, 1)
        text:SetShadowOffset(1, -1)
        overlays[frame] = text
    end
    return text
end

-- -------------------------------------------------------------------- badges

-- The Delves header widget (UIWidgetTemplateScenarioHeaderDelves) draws its
-- lives remaining -- the heart and its number -- in CurrencyContainer, a
-- HorizontalLayoutFrame holding UIWidgetBaseCurrencyTemplate frames: icon,
-- a 5px gap, count. We put one more frame of that shape in the container at
-- layoutIndex 0, so Blizzard's own layout places it left of the heart with
-- the container's spacing, and we take the heart's icon size, font and colour
-- so the row reads as one. The art defaults to the skull raid marker, the
-- game's own "enemies" mark; /dec icon and /dec size change both live,
-- because judging either one needs seeing it in a real Delve.
local BADGE_LAYOUT_INDEX = 0
-- Used when there is no currency frame to take a size from.
local BADGE_ICON_SIZE = 16
local MIN_ICON_SCALE, MAX_ICON_SCALE = 0.3, 2
local MIN_ICON_GAP, MAX_ICON_GAP = 0, 20

-- Icons worth trying, in the order /dec icon lists them. "heart" copies the
-- neighbouring currency icon and "affix" the reporting affix's own spell
-- icon, so both follow whatever the client shows; the rest are fixed art.
-- Any texture path or atlas name can be given to /dec icon instead.
local ICONS = {
    { name = "skull",  texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8" },
    { name = "swords", atlas = "roleicon-tiny-dps" },
    { name = "cross",  texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7" },
    { name = "heart",  copyNeighbour = true },
    { name = "affix",  fromSpell = true },
}
local ICONS_BY_NAME = {}
for _, choice in ipairs(ICONS) do
    ICONS_BY_NAME[choice.name] = choice
end

local function IconNames()
    local names = {}
    for i, choice in ipairs(ICONS) do
        names[i] = choice.name
    end
    return table.concat(names, ", ")
end

local function SpellTexture(spellID)
    if spellID and C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    end
    return nil
end

-- Paint the chosen art onto the badge's texture. `model` is the neighbouring
-- currency frame and `source` the frame the count was read from, when the
-- choice needs one; either may be missing, and then the default is used.
local function ApplyIcon(texture, model, source)
    local choice = ICONS_BY_NAME[db.icon]
    if choice and choice.copyNeighbour then
        local neighbour = model and model.Icon and model.Icon:GetTexture()
        if neighbour then
            texture:SetTexture(neighbour)
            return
        end
    elseif choice and choice.fromSpell then
        local spellTexture = SpellTexture(source and source.spellID)
        if spellTexture then
            texture:SetTexture(spellTexture)
            return
        end
    elseif choice and choice.atlas then
        texture:SetAtlas(choice.atlas)
        return
    elseif choice and choice.texture then
        texture:SetTexture(choice.texture)
        return
    elseif not choice then
        -- Whatever was typed: a texture path, or an atlas name if that fails.
        texture:SetTexture(db.icon)
        if not texture:GetTexture() then
            texture:SetAtlas(db.icon)
        end
        return
    end
    texture:SetTexture(ICONS[1].texture)
end

-- The leftmost currency frame the header currently shows (the heart), to
-- take size, font and colour from.
local function ModelCurrency(header)
    local pool = header.currencyPool
    if type(pool) ~= "table" or type(pool.EnumerateActive) ~= "function" then
        return nil
    end
    local best
    for frame in pool:EnumerateActive() do
        if not best or (frame.layoutIndex or 0) < (best.layoutIndex or 0) then
            best = frame
        end
    end
    return best
end

local function BadgeTooltip(self)
    if not self.tooltipText then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.tooltipText, 1, 1, 1, 1, true)
    GameTooltip:Show()
end

local function BadgeFor(container)
    local badge = badges[container]
    if not badge then
        badge = CreateFrame("Frame", nil, container)
        badge.layoutIndex = BADGE_LAYOUT_INDEX
        badge.Icon = badge:CreateTexture(nil, "OVERLAY")
        badge.Icon:SetPoint("LEFT")
        badge.Text = badge:CreateFontString(nil, "OVERLAY", "GameFontNormal_NoShadow")
        badge.Text:SetPoint("LEFT", badge.Icon, "RIGHT", 0, 0)
        badge:SetScript("OnEnter", BadgeTooltip)
        badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
        badges[container] = badge
    end
    return badge
end

-- Draw the count in the header's currency row, matched to the heart beside
-- it. `source` is the frame the count was read from, for the affix icon.
-- Returns the badge, or nil when this widget has no such row.
local function PaintBadge(header, remaining, tooltipText, source)
    local container = header.CurrencyContainer
    if type(container) ~= "table" then
        return nil
    end
    local badge = BadgeFor(container)
    local model = ModelCurrency(header)
    local icon = model and model.Icon
    ApplyIcon(badge.Icon, model, source)
    badge.Icon:SetVertexColor(1, 1, 1, 1)
    local scale = db.iconScale or DEFAULTS.iconScale
    badge.Icon:SetSize(((icon and icon:GetWidth()) or BADGE_ICON_SIZE) * scale,
        ((icon and icon:GetHeight()) or BADGE_ICON_SIZE) * scale)
    if model and model.Text then
        local font = model.Text:GetFontObject()
        if font then
            badge.Text:SetFontObject(font)
        end
        badge.Text:SetTextColor(model.Text:GetTextColor())
    end
    local gap = db.iconGap or DEFAULTS.iconGap
    badge.Text:SetPoint("LEFT", badge.Icon, "RIGHT", gap, 0)
    badge.Text:SetText(remaining)
    badge.tooltipText = tooltipText
    local iconWidth = badge.Icon:GetWidth() or BADGE_ICON_SIZE
    local iconHeight = badge.Icon:GetHeight() or BADGE_ICON_SIZE
    local textWidth = badge.Text:GetStringWidth() or 0
    local textHeight = badge.Text:GetStringHeight() or 0
    badge:SetSize(iconWidth + gap + textWidth, math.max(iconHeight, textHeight))
    badge:Show()
    if type(container.Layout) == "function" then
        container:Layout()
    end
    return badge
end

local function HideBadge(container, badge)
    if not badge:IsShown() then
        return
    end
    badge:Hide()
    if type(container.Layout) == "function" then
        container:Layout()
    end
end

local function UpdateOverlays()
    if not (db and db.enabled and InDelve()) then
        for _, text in pairs(overlays) do
            text:Hide()
        end
        for container, badge in pairs(badges) do
            HideBadge(container, badge)
        end
        return
    end
    local painted, shownBadges = {}, {}
    for _, frame in ipairs(WidgetFrames()) do
        local remaining, text, target = WidgetRemaining(frame)
        if remaining then
            local badge = PaintBadge(frame, remaining, text, target)
            if badge then
                shownBadges[badge] = true
            else
                local overlay = OverlayFor(target)
                overlay:SetText(remaining)
                overlay:Show()
                painted[target] = true
            end
        end
    end
    for target, text in pairs(overlays) do
        if not painted[target] then
            text:Hide()
        end
    end
    for container, badge in pairs(badges) do
        if not shownBadges[badge] then
            HideBadge(container, badge)
        end
    end
end

local function ScheduleScan()
    if scanPending then
        return
    end
    scanPending = true
    C_Timer.After(SCAN_DELAY, function()
        scanPending = false
        UpdateOverlays()
    end)
end

-- ------------------------------------------------------------------ commands

local function Plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\n", " / "))
end

local function Status()
    local counts = {}
    for _, frame in ipairs(WidgetFrames()) do
        local remaining = WidgetRemaining(frame)
        if remaining then
            counts[#counts + 1] = remaining
        end
    end
    Print(("%s; in a Delve: %s; icon %s at %.2f, gap %d; enemy groups remaining: %s"):format(
        db.enabled and "on" or "off",
        InDelve() and "yes" or "no",
        tostring(db.icon), db.iconScale or DEFAULTS.iconScale, db.iconGap or DEFAULTS.iconGap,
        #counts > 0 and table.concat(counts, ", ") or "nothing found"))
end

-- Both of these take effect on the next repaint, which is immediate, so the
-- look can be settled in one visit to a Delve instead of one per reload.
local function SetIcon(value)
    if value == "" then
        Print(("icon %s; try one of: %s, or a texture path or atlas name."):format(
            tostring(db.icon), IconNames()))
        return
    end
    db.icon = value
    UpdateOverlays()
    Print("icon " .. value)
end

local function SetScale(value)
    local scale = tonumber(value)
    if not scale then
        Print(("size %.2f; give a number between %.1f and %.1f (1 matches the heart)."):format(
            db.iconScale or DEFAULTS.iconScale, MIN_ICON_SCALE, MAX_ICON_SCALE))
        return
    end
    db.iconScale = math.max(MIN_ICON_SCALE, math.min(MAX_ICON_SCALE, scale))
    UpdateOverlays()
    Print(("size %.2f"):format(db.iconScale))
end

local function SetGap(value)
    local gap = tonumber(value)
    if not gap then
        Print(("gap %d; give a number of pixels between %d and %d (the game uses 5)."):format(
            db.iconGap or DEFAULTS.iconGap, MIN_ICON_GAP, MAX_ICON_GAP))
        return
    end
    db.iconGap = math.max(MIN_ICON_GAP, math.min(MAX_ICON_GAP, math.floor(gap + 0.5)))
    UpdateOverlays()
    Print(("gap %d"):format(db.iconGap))
end

local function Reset()
    db.icon, db.iconScale, db.iconGap = DEFAULTS.icon, DEFAULTS.iconScale, DEFAULTS.iconGap
    UpdateOverlays()
    Print(("back to the defaults: icon %s at %.2f, gap %d"):format(db.icon, db.iconScale, db.iconGap))
end

local function Debug()
    local frames = WidgetFrames()
    local registry = UIWidgetManager and UIWidgetManager.registeredWidgetContainers
    Print(("%d widget frame(s) (widget registry %s):"):format(#frames, registry and "present" or "missing"))
    for _, frame in ipairs(frames) do
        local info = WidgetInfo(frame)
        local n, text = WidgetRemaining(frame)
        local tooltips = FrameTooltips(frame, 0)
        local infoKeys = {}
        if info then
            for k in pairs(info) do
                infoKeys[#infoKeys + 1] = tostring(k)
            end
            table.sort(infoKeys)
        end
        Print(("  widget %s type %s shown %s | remaining %s | %d tooltip(s) | info keys: %s"):format(
            tostring(frame.widgetID), tostring(frame.widgetType), frame:IsShown() and "yes" or "no",
            tostring(n), #tooltips, info and table.concat(infoKeys, ",") or "none"))
        if text then
            Print("    from: " .. Plain(text):sub(1, 120))
        end
        if info and type(info.spells) == "table" then
            for i, spell in ipairs(info.spells) do
                Print(("    spell %d: id %s | tooltip '%s' | description '%s'"):format(
                    i, tostring(spell.spellID), Plain(spell.tooltip or ""):sub(1, 60),
                    Plain(spell.spellID and SpellDescription(spell.spellID) or ""):sub(1, 90)))
            end
        end
        for i = 1, math.min(#tooltips, 6) do
            Print(("    tooltip %d: %s"):format(i, Plain(tooltips[i]):sub(1, 120)))
        end
    end
end

local USAGE = "usage: /dec on|off, /dec icon <name>, /dec size <n>, /dec gap <n>, /dec reset, /dec status, /dec debug"

local function SlashHandler(msg)
    msg = msg or ""
    local cmd = msg:lower():match("^%s*(%S*)")
    -- The argument keeps its case: texture paths are case-sensitive.
    local arg = msg:match("^%s*%S*%s+(.-)%s*$") or ""
    if cmd == "icon" then
        SetIcon(arg)
        return
    elseif cmd == "size" or cmd == "scale" then
        SetScale(arg)
        return
    elseif cmd == "gap" then
        SetGap(arg)
        return
    elseif cmd == "reset" then
        Reset()
        return
    end
    if cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        UpdateOverlays()
        Status()
    elseif cmd == "debug" then
        Debug()
    elseif cmd == "status" or cmd == "" then
        Status()
    else
        Status()
        Print(USAGE)
    end
end

-- ------------------------------------------------------------------- options

-- Esc > Options > AddOns > Delve Enemy Counter. The proxy setting reads and
-- writes our saved table directly, so the panel and /dec always agree.
-- Missing or changed Blizzard API: the panel is skipped and /dec still works.
local function RegisterOptions()
    local category = Settings.RegisterVerticalLayoutCategory(ADDON_TITLE)
    local setting = Settings.RegisterProxySetting(category, "DelveEnemyCounter_enabled",
        Settings.VarType.Boolean, "Show enemy groups remaining",
        DEFAULTS.enabled and Settings.Default.True or Settings.Default.False,
        function() return db.enabled == true end,
        function(value)
            db.enabled = value and true or false
            UpdateOverlays()
        end)
    Settings.CreateCheckbox(category, setting,
        "Keep the Nemesis Influence \"enemy groups remaining\" number in the Delve tracker, beside the lives remaining, so it can be read without a mouse.")
    Settings.RegisterAddOnCategory(category)
end

local function SetupOptions()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting
            and Settings.CreateCheckbox and Settings.RegisterAddOnCategory
            and Settings.VarType and Settings.Default) then
        return
    end
    local ok, err = pcall(RegisterOptions)
    if not ok then
        Print("options panel unavailable (" .. tostring(err) .. "); /dec still works.")
    end
end

-- -------------------------------------------------------------------- events

local function CopyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end
            CopyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then
            return
        end
        DelveEnemyCounterDB = DelveEnemyCounterDB or {}
        db = DelveEnemyCounterDB
        CopyDefaults(db, DEFAULTS)
        SetupOptions()
        self:UnregisterEvent("ADDON_LOADED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        self:RegisterEvent("UPDATE_UI_WIDGET")
        return
    end
    ScheduleScan()
end)

SLASH_DELVEENEMYCOUNTER1 = "/dec"
SLASH_DELVEENEMYCOUNTER2 = "/delveenemycounter"
SlashCmdList.DELVEENEMYCOUNTER = SlashHandler

-- Exposed for tests only.
ns.TooltipRemaining = TooltipRemaining
ns.RatioInTable = RatioInTable
ns.WidgetRemaining = WidgetRemaining
ns.UpdateOverlays = UpdateOverlays
ns.SlashHandler = SlashHandler
ns.GetOverlays = function() return overlays end
ns.GetBadges = function() return badges end
ns.frame = frame
