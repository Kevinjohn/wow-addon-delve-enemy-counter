-- Behaviour harness: loads DelveEnemyCounter.lua under a stubbed WoW API and
-- drives the widget overlay:
--   * the "n / m" in a widget's tooltip is parsed as the last ratio in it,
--   * inside a Delve, every widget frame the widget manager knows about is
--     read -- from the widget manager's own data, from an affix spell's live
--     description, or from a tooltip kept on the frame or one of its
--     children -- and the remaining count is shown: in the Delves header's
--     own lives-remaining row when there is one, painted over the icon
--     otherwise,
--   * the number follows the live data on every widget update, and frames
--     without a ratio are left alone,
--   * the overlay is hidden outside a Delve and when the addon is off,
--   * /dec on|off|status|debug report and toggle, and the saved setting
--     survives a /reload,
--   * the Blizzard Settings panel gets one tick box that changes it live,
--     and its absence is harmless.
--
-- Run from the repo root:  luajit tests/run.lua   (any Lua >= 5.1 works)

local failures, checks = {}, 0
local function check(ok, label)
	checks = checks + 1
	if not ok then
		failures[#failures + 1] = label
		io.write("FAIL  ", label, "\n")
	end
end

-- ---------------------------------------------------------------- WoW stubs
local world = {
	difficultyID = 0, -- 208 = Delves
	instanceID = 100,
}
local chat = {}

_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) chat[#chat + 1] = msg end }
_G.GetInstanceInfo = function()
	return "Earthcrawl Mines", "scenario", world.difficultyID, "Delve", 5, 0, false, world.instanceID
end
_G.C_Timer = { After = function(_, fn) fn() end } -- run scheduled scans immediately
_G.SlashCmdList = {}

-- Frames: any method not modelled here is a no-op.
local function widget()
	local w = { events = {}, shown = false, scripts = {} }
	function w:RegisterEvent(e) self.events[e] = true end
	function w:UnregisterEvent(e) self.events[e] = nil end
	function w:SetScript(name, fn)
		self.scripts[name] = fn
		if name == "OnEvent" then self.handler = fn end
	end
	function w:Show() self.shown = true end
	function w:Hide() self.shown = false end
	function w:IsShown() return self.shown end
	function w:SetText(t) self.textValue = t end
	function w:CreateFontString() return widget() end
	function w:CreateTexture() return widget() end
	-- false, not nil: a nil field would fall through to the catch-all below
	function w:SetTexture(t) self.texture, self.atlas = t or false, false end
	function w:GetTexture() return self.texture end
	function w:SetAtlas(a) self.atlas, self.texture = a, false end
	function w:Layout() self.layouts = (rawget(self, "layouts") or 0) + 1 end
	return setmetatable(w, { __index = function() return function() end end })
end
_G.CreateFrame = function() return widget() end

-- Frames the client would enumerate: a Nemesis widget whose data comes from
-- the widget manager, a widget whose tooltip sits on a child frame, a widget
-- without a ratio, and a plain frame.
local NEMESIS_TIP = "Nemesis Influence\nThe Nemesis's allies are wandering about the delve.\n\nEnemy groups remaining: 1 / 4"
local nemesisWidget = widget(); nemesisWidget.widgetID = 6001; nemesisWidget.widgetType = 6
local childWidget = widget(); childWidget.widgetID = 6003; childWidget.widgetType = 6
local childIcon = widget(); childIcon.tooltip = "Something else: 2 / 3"
function childWidget:GetChildren() return childIcon end
local otherWidget = widget(); otherWidget.widgetID = 6002; otherWidget.widgetType = 6
-- The Delves header: affix spells with empty tooltips whose live description
-- carries the number, and icon children keyed by spellID.
-- Its lives-remaining row is the real thing in miniature: a layout frame
-- holding one pooled currency frame (the heart and its count).
local headerWidget = widget(); headerWidget.widgetID = 6183; headerWidget.widgetType = 29
local iconA = widget(); iconA.spellID = 1001
local iconB = widget(); iconB.spellID = 1002
function headerWidget:GetChildren() return iconA, iconB end
local heart = widget(); heart.layoutIndex = 1
heart.Icon = widget(); heart.Icon:SetTexture("Interface\\Icons\\Heart")
heart.Text = widget()
local currencyContainer = widget()
headerWidget.CurrencyContainer = currencyContainer
headerWidget.currencyPool = { EnumerateActive = function()
	local done = false
	return function()
		if done then return nil end
		done = true
		return heart
	end
end }
local descriptions = {
	[1001] = "Curiosity buff.",
	[1002] = "The Nemesis's allies are wandering.\n\nEnemy groups remaining: 3 / 4",
}
_G.C_Spell = {
	GetSpellDescription = function(id) return descriptions[id] end,
	GetSpellTexture = function(id) return "Interface\\Icons\\Spell_" .. tostring(id) end,
}
local plain = widget()
-- Widget containers as the widget manager registers them: one keyed by the
-- container frame, one nested under a set ID, plus a stray non-container.
local containerA = widget(); containerA.widgetFrames = { [6001] = nemesisWidget, [6002] = otherWidget }
local containerB = widget(); containerB.widgetFrames = { [6003] = childWidget, [6183] = headerWidget }
_G.UIWidgetManager = {
	registeredWidgetContainers = { [containerA] = true, [42] = { [containerB] = true }, [plain] = true },
	widgetVisTypeInfo = {
		[6] = { visInfoDataFunction = function(id)
			if id == 6001 then return { spellInfo = { tooltip = NEMESIS_TIP, name = "Nemesis Influence" } } end
			if id == 6002 then return { spellInfo = { tooltip = "Companion buff" } } end
			return nil
		end },
		[29] = { visInfoDataFunction = function(id)
			if id == 6183 then
				return { headerText = "Gnarldor Isle", tooltip = "", tierText = "11",
					spells = { { spellID = 1001, tooltip = "" }, { spellID = 1002, tooltip = "" } } }
			end
			return nil
		end },
	},
}

-- Blizzard Settings panel stub: records proxy settings by variable name so a
-- test can flip a box (set) and read what the panel would show (get).
local settings = { proxies = {}, checkboxes = 0, categories = {} }
_G.Settings = {
	VarType = { Boolean = "boolean", Number = "number", String = "string" },
	Default = { True = true, False = false },
	RegisterVerticalLayoutCategory = function(name)
		local c = { name = name }
		settings.categories[#settings.categories + 1] = c
		return c
	end,
	RegisterProxySetting = function(category, variable, varType, name, default, getValue, setValue)
		assert(category and variable and varType and name and getValue and setValue, "proxy setting arguments")
		assert(settings.proxies[variable] == nil, "duplicate setting variable " .. variable)
		local p = { name = name, varType = varType, default = default, get = getValue, set = setValue }
		settings.proxies[variable] = p
		return p
	end,
	CreateCheckbox = function(_, setting)
		assert(setting.varType == "boolean")
		settings.checkboxes = settings.checkboxes + 1
	end,
	RegisterAddOnCategory = function(c) c.registered = true end,
}

-- ---------------------------------------------------------------- load addon
local ns, frame, overlays, badges, db
local function load()
	settings.proxies, settings.checkboxes = {}, 0
	ns = {}
	assert(loadfile("DelveEnemyCounter.lua"))("DelveEnemyCounter", ns)
	frame = ns.frame
	frame.handler(frame, "ADDON_LOADED", "DelveEnemyCounter")
	overlays = ns.GetOverlays()
	badges = ns.GetBadges()
	db = _G.DelveEnemyCounterDB
end
local function headerBadge() return badges[currencyContainer] end
local function fire(event, ...) frame.handler(frame, event, ...) end
local function proxy(key) return settings.proxies["DelveEnemyCounter_" .. key] end

-- ------------------------------------------------------------------- loading
do
	local probe = {}
	assert(loadfile("DelveEnemyCounter.lua"))("DelveEnemyCounter", probe)
	probe.frame.handler(probe.frame, "ADDON_LOADED", "SomeOtherAddon")
	check(_G.DelveEnemyCounterDB == nil, "ignores ADDON_LOADED for other addons")
	check(probe.TooltipRemaining("Enemy groups remaining: 1 / 4") == "1"
		and probe.TooltipRemaining("3/12 done, 0 / 4 left") == "0"
		and probe.TooltipRemaining("no ratio here") == nil and probe.TooltipRemaining(nil) == nil,
		"tooltip ratio parsing takes the last n / m")
	check(probe.RatioInTable({ a = { b = { c = "left: 2 / 9" } } }, 0) == "2"
		and probe.RatioInTable({ a = "none" }, 0) == nil and probe.RatioInTable("string", 0) == nil,
		"nested tables are searched for a ratio, depth-limited")
end

load()
check(db.enabled == true, "settings get defaults")
check(frame.events.UPDATE_UI_WIDGET and frame.events.PLAYER_ENTERING_WORLD
	and frame.events.ZONE_CHANGED_NEW_AREA and not frame.events.ADDON_LOADED,
	"registers the widget and zone events after load")
check(type(SlashCmdList.DELVEENEMYCOUNTER) == "function" and SLASH_DELVEENEMYCOUNTER1 == "/dec",
	"registers the /dec slash command")

-- ------------------------------------------------------------ outside a Delve
fire("UPDATE_UI_WIDGET")
check(next(overlays) == nil and next(badges) == nil, "nothing is painted outside a Delve")

-- ---------------------------------------------------------------- in a Delve
world.difficultyID = 208
fire("PLAYER_ENTERING_WORLD")
check(overlays[nemesisWidget] and overlays[nemesisWidget].shown and overlays[nemesisWidget].textValue == "1",
	"nemesis widget gets its remaining count painted from widget-manager data")
check(overlays[childWidget] and overlays[childWidget].textValue == "2", "tooltip on a child frame is found")
check(headerBadge() and headerBadge().shown and headerBadge().Text.textValue == "3",
	"Delves header: number from the spell description, shown in the lives row")
check(overlays[iconA] == nil and overlays[iconB] == nil and overlays[headerWidget] == nil,
	"and nothing is painted over the affix icons")
check(headerBadge().layoutIndex == 0 and (currencyContainer.layouts or 0) > 0,
	"the badge is laid out left of the heart by the container itself")
check(headerBadge().Icon.texture == "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",
	"the badge uses the skull marker, not the neighbouring currency's icon")
check(overlays[otherWidget] == nil and overlays[plain] == nil, "frames without a ratio are untouched")

descriptions[1002] = descriptions[1002]:gsub("3 / 4", "2 / 4")
fire("UPDATE_UI_WIDGET")
check(headerBadge().Text.textValue == "2", "the badge follows the live description")
NEMESIS_TIP = NEMESIS_TIP:gsub("1 / 4", "0 / 4")
fire("UPDATE_UI_WIDGET")
check(overlays[nemesisWidget].textValue == "0", "overlay follows the tooltip")

-- once the affix is gone entirely the overlay is taken down, not left stale
local savedDescription = descriptions[1002]
descriptions[1002] = "The Nemesis's allies are wandering."
fire("UPDATE_UI_WIDGET")
check(headerBadge().shown == false, "an affix that stops reporting a ratio loses its number")
descriptions[1002] = savedDescription
fire("UPDATE_UI_WIDGET")
check(headerBadge().shown == true and headerBadge().Text.textValue == "2", "and gets it back when it returns")

-- --------------------------------------------------------------- icon + size
do
	local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
	check(db.icon == "skull" and db.iconScale == 0.65 and db.iconGap == 7 and db.iconY == 1
		and db.badgeX == -10, "icon, size, gap and both nudges have defaults")
	check(headerBadge().rightPadding == 10,
		"the badge asks the container for room on its right, which shifts it left")

	ns.SlashHandler("icon heart")
	check(headerBadge().Icon.texture == "Interface\\Icons\\Heart", "/dec icon heart copies the neighbour")
	ns.SlashHandler("icon affix")
	check(headerBadge().Icon.texture == "Interface\\Icons\\Spell_1002",
		"/dec icon affix uses the reporting spell's own icon")
	ns.SlashHandler("icon swords")
	check(headerBadge().Icon.atlas == "roleicon-tiny-dps" and headerBadge().Icon.texture == false,
		"/dec icon swords sets an atlas")
	ns.SlashHandler("icon Interface\\Icons\\INV_Misc_Bone_01")
	check(headerBadge().Icon.texture == "Interface\\Icons\\INV_Misc_Bone_01",
		"/dec icon takes a texture path as typed, case kept")

	ns.SlashHandler("size 1.25")
	check(db.iconScale == 1.25, "/dec size sets the size")
	ns.SlashHandler("size 99")
	check(db.iconScale == 2, "/dec size clamps to the top of the range")
	ns.SlashHandler("size -1")
	check(db.iconScale == 0.3, "and to the bottom")
	local before = #chat
	ns.SlashHandler("size")
	check(#chat > before and chat[#chat]:find("size 0.30", 1, true) ~= nil, "/dec size with no number reports it")
	before = #chat
	ns.SlashHandler("icon")
	check(chat[#chat]:find("skull, swords, cross, heart, affix", 1, true) ~= nil,
		"/dec icon with no name lists the choices")

	ns.SlashHandler("gap 2")
	check(db.iconGap == 2, "/dec gap sets the space between icon and count")
	ns.SlashHandler("gap 99")
	check(db.iconGap == 20, "/dec gap clamps")

	ns.SlashHandler("x 4")
	check(db.badgeX == 4 and headerBadge().rightPadding == -4, "/dec x shifts the whole badge")
	ns.SlashHandler("x -99")
	check(db.badgeX == -40, "/dec x clamps")

	ns.SlashHandler("y 3")
	check(db.iconY == 3, "/dec y lifts the icon")
	ns.SlashHandler("y -99")
	check(db.iconY == -10, "/dec y clamps")

	ns.SlashHandler("reset")
	check(db.icon == "skull" and db.iconScale == 0.65 and db.iconGap == 7 and db.iconY == 1
		and db.badgeX == -10 and headerBadge().Icon.texture == SKULL,
		"/dec reset puts them all back")

	ns.SlashHandler("icon swords")
	load()
	check(db.icon == "swords", "the icon choice survives a /reload")
	ns.SlashHandler("reset")
	fire("UPDATE_UI_WIDGET")
end

-- -------------------------------------------------------------------- /dec
ns.SlashHandler("debug")
local sawWidget = false
for i = math.max(1, #chat - 30), #chat do
	if chat[i]:find("widget 6001", 1, true) and chat[i]:find("remaining 0", 1, true) then sawWidget = true end
end
check(sawWidget, "/dec debug lists widgets with their remaining count")

ns.SlashHandler("status")
check(chat[#chat]:find("in a Delve: yes", 1, true) ~= nil
	and chat[#chat]:find("enemy groups remaining: ", 1, true) ~= nil,
	"/dec status reports the state and the groups remaining")
do
	-- the counts are gathered by iterating the widget registry, so compare
	-- them as a set rather than in an order pairs() does not promise
	local found = {}
	for n in (chat[#chat]:match("enemy groups remaining: (.*)$") or ""):gmatch("%d+") do found[#found + 1] = n end
	table.sort(found)
	check(table.concat(found, ",") == "0,2,2", "status lists every widget's count (got " .. table.concat(found, ",") .. ")")
end

ns.SlashHandler("off")
check(db.enabled == false and overlays[nemesisWidget].shown == false and headerBadge().shown == false,
	"/dec off hides the numbers")
ns.SlashHandler("on")
check(db.enabled == true and overlays[nemesisWidget].shown == true, "/dec on shows them again")
local before = #chat
ns.SlashHandler("nonsense")
check(chat[#chat]:find("usage: /dec", 1, true) ~= nil and #chat > before, "an unknown command prints the usage")

world.difficultyID = 0
fire("ZONE_CHANGED_NEW_AREA")
check(overlays[nemesisWidget].shown == false and headerBadge().shown == false, "hidden outside a Delve")
world.difficultyID = 208
fire("PLAYER_ENTERING_WORLD")
check(overlays[nemesisWidget].shown == true, "shown again on returning to a Delve")

-- ------------------------------------------------------------------ options
check(settings.categories[#settings.categories].name == "Delve Enemy Counter"
	and settings.categories[#settings.categories].registered, "options category registered under AddOns")
check(settings.checkboxes == 1 and proxy("enabled") and proxy("enabled").get() == true,
	"one tick box, on by default")
proxy("enabled").set(false)
check(db.enabled == false and overlays[nemesisWidget].shown == false, "unticking the box hides the numbers live")
proxy("enabled").set(true)
check(db.enabled == true and overlays[nemesisWidget].shown == true, "ticking it back shows them again")

ns.SlashHandler("off")
check(proxy("enabled").get() == false, "/dec off unticks the box")
ns.SlashHandler("on")

-- ------------------------------------------------------------------- reloads
ns.SlashHandler("off")
load()
check(db.enabled == false, "the setting survives a /reload")
fire("PLAYER_ENTERING_WORLD")
check(next(overlays) == nil, "and nothing is painted while it is off")
ns.SlashHandler("on")
fire("UPDATE_UI_WIDGET")
check(overlays[nemesisWidget].textValue == "0", "turning it back on paints again after a reload")

do
	local saved = _G.Settings
	_G.Settings = nil
	before = #chat
	load()
	check(#chat == before and db.enabled == true, "no Settings API: loads quietly, /dec still works")
	ns.SlashHandler("status")
	check(chat[#chat]:find("on;", 1, true) ~= nil, "and /dec status still answers")
	_G.Settings = saved
	load()
	check(proxy("enabled") ~= nil, "panel registered again after a /reload")
end

do
	local saved = _G.UIWidgetManager
	_G.UIWidgetManager = nil
	before = #chat
	fire("UPDATE_UI_WIDGET")
	ns.SlashHandler("debug")
	check(chat[#chat]:find("0 widget frame(s) (widget registry missing)", 1, true) ~= nil,
		"no widget manager: no error, debug says the registry is missing")
	_G.UIWidgetManager = saved
end

io.write(("%d checks, %d failures\n"):format(checks, #failures))
if #failures > 0 then
	os.exit(1)
end
