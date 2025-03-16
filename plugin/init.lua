local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

local pub = {}

local plugin_dir

--- checks if the user is on windows
local is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
local separator = is_windows and "\\" or "/"

--- Returns the name of the package, used when requiring modules
--- @return string
local function get_require_path()
	local paths = {
		-- MLFlexer repo
		"httpssCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDswezterm",
		"httpssCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDsweztermsZs",
		"httpsCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDswezterm",
		"httpsCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDsweztermsZs",
		-- chrisgve repo
		"httpssCssZssZsgithubsDscomsZschrisgvesZsresurrectsDswezterm",
		"httpssCssZssZsgithubsDscomsZschrisgvesZsresurrectsDsweztermsZs",
		"httpsCssZssZsgithubsDscomsZschrisgvesZsresurrectsDswezterm",
		"httpsCssZssZsgithubsDscomsZschrisgvesZsresurrectsDsweztermsZs",
	}
	for _, path in ipairs(paths) do
		for _, plugin in ipairs(wezterm.plugin.list()) do
			if plugin.component == path then
				return plugin.plugin_dir
			end
		end
	end
	return ""
end

--- adds the wezterm plugin directory to the lua path
local function enable_sub_modules()
	plugin_dir = wezterm.plugin.list()[1].plugin_dir:gsub(separator .. "[^" .. separator .. "]*$", "")
	package.path = package.path .. ";" .. get_require_path() .. separator .. "plugin" .. separator .. "?.lua"
end

local function init()
	enable_sub_modules()

	require("resurrect.state_manager").change_state_save_dir(get_require_path() .. separator .. "state" .. separator)

	-- Export submodules
	pub.workspace_state = require("resurrect.workspace_state")
	pub.window_state = require("resurrect.window_state")
	pub.tab_state = require("resurrect.tab_state")
	pub.fuzzy_loader = require("resurrect.fuzzy_loader")
	pub.state_manager = require("resurrect.state_manager")
end

init()

return pub
