std = "lua51"
max_line_length = false
self = false

exclude_files = {
	".luacheckrc",
	"tests/*.lua", -- plain Lua, run outside the WoW sandbox
}

-- The standard addon header is `local addonName, ns = ...`; OnEvent handlers
-- take a `self` they don't always use.
ignore = { "212/self" }

-- Globals this addon defines: its saved-variables table and the slash-command
-- registration globals (SlashCmdList is mutated, the SLASH_* names are set).
globals = {
	"DelveEnemyCounterDB",
	"SlashCmdList",
	"SLASH_DELVEENEMYCOUNTER1",
	"SLASH_DELVEENEMYCOUNTER2",
}

read_globals = {
	"CreateFrame",
	"UIWidgetManager",
	"DEFAULT_CHAT_FRAME",
	"Settings",
	"GetInstanceInfo",
	"DifficultyUtil",
	"C_Timer",
	"C_Spell",
	"GameTooltip",
}
