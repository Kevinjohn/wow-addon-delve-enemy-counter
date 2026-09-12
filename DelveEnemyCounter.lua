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
    enabled = true, -- master switch
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
-- the container's spacing, and we copy the heart's icon, size, font and
-- colour so the row reads as one. The borrowed heart is a placeholder until
-- there is a monster icon to use instead.
local BADGE_LAYOUT_INDEX = 0
local BADGE_ICON_GAP = 5
-- Only used when there is no currency frame to copy: the skull raid marker,
-- which is always present and at least reads as "enemies".
local FALLBACK_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local FALLBACK_ICON_SIZE = 16

-- The leftmost currency frame the header currently shows (the heart), to
-- copy its look from.
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
        badge.Text:SetPoint("LEFT", badge.Icon, "RIGHT", BADGE_ICON_GAP, 0)
        badge:SetScript("OnEnter", BadgeTooltip)
        badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
        badges[container] = badge
    end
    return badge
end

-- Draw the count in the header's currency row, matching the heart beside it.
-- Returns the badge, or nil when this widget has no such row.
local function PaintBadge(header, remaining, tooltipText)
    local container = header.CurrencyContainer
    if type(container) ~= "table" then
        return nil
    end
    local badge = BadgeFor(container)
    local model = ModelCurrency(header)
    local icon = model and model.Icon
    if icon then
        badge.Icon:SetTexture(icon:GetTexture())
        badge.Icon:SetSize(icon:GetWidth() or FALLBACK_ICON_SIZE, icon:GetHeight() or FALLBACK_ICON_SIZE)
    else
        badge.Icon:SetTexture(FALLBACK_ICON)
        badge.Icon:SetSize(FALLBACK_ICON_SIZE, FALLBACK_ICON_SIZE)
    end
    if model and model.Text then
        local font = model.Text:GetFontObject()
        if font then
            badge.Text:SetFontObject(font)
        end
        badge.Text:SetTextColor(model.Text:GetTextColor())
    end
    badge.Text:SetText(remaining)
    badge.tooltipText = tooltipText
    local iconWidth = badge.Icon:GetWidth() or FALLBACK_ICON_SIZE
    local iconHeight = badge.Icon:GetHeight() or FALLBACK_ICON_SIZE
    local textWidth = badge.Text:GetStringWidth() or 0
    local textHeight = badge.Text:GetStringHeight() or 0
    badge:SetSize(iconWidth + BADGE_ICON_GAP + textWidth, math.max(iconHeight, textHeight))
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
            local badge = PaintBadge(frame, remaining, text)
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
    Print(("%s; in a Delve: %s; enemy groups remaining: %s"):format(
        db.enabled and "on" or "off",
        InDelve() and "yes" or "no",
        #counts > 0 and table.concat(counts, ", ") or "nothing found"))
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

local USAGE = "usage: /dec on|off, /dec status, /dec debug"

local function SlashHandler(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")
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
