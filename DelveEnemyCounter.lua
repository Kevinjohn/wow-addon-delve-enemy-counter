-- Delve Enemy Counter
--
-- Inside a Delve, the tracker shows affixes such as Nemesis Influence as UI
-- widget icons whose only readable state is a mouse-over tooltip like
-- "Enemy groups remaining: 1 / 4". Those are enemy groups, not individual
-- enemies: the count drops by one when a whole pack is cleared.
--
-- Hover is the only way the game offers that number, which puts it out of
-- reach of anyone not playing with a mouse. This addon paints it in white
-- over the icon and leaves it there, so no pointer is needed to read it.
-- Nothing happens outside Delves.
--
-- How it works: each widget frame carries widgetID and widgetType; the
-- widget's data comes from the type's visualization-info function
-- (registered in Blizzard's UIWidgetManager), and the tooltip mixin also
-- keeps the text on the frame or one of its children. Whichever yields
-- "n / m", n is painted over the icon.

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

local function UpdateOverlays()
    if not (db and db.enabled and InDelve()) then
        for _, text in pairs(overlays) do
            text:Hide()
        end
        return
    end
    local painted = {}
    for _, frame in ipairs(WidgetFrames()) do
        local remaining, _, target = WidgetRemaining(frame)
        if remaining then
            local text = OverlayFor(target)
            text:SetText(remaining)
            text:Show()
            painted[target] = true
        end
    end
    for target, text in pairs(overlays) do
        if not painted[target] then
            text:Hide()
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
        "Keep the Nemesis Influence \"enemy groups remaining\" number on its Delve tracker icon, so it can be read without a mouse.")
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
ns.frame = frame
