local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local dev = wezterm.plugin.require("https://github.com/chrisgve/dev.wezterm")

local pub = {}

--- checks if the user is on windows
local is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
local separator = is_windows and "\\" or "/"

--- Returns the name of the package, used when requiring modules
--- @return string|nil
local function get_require_path()
	local paths = {
		-- chrisgve
		"httpssCssZssZsgithubsDscomsZschrisgvesZsresurrectsDswezterm",
		"httpssCssZssZsgithubsDscomsZschrisgvesZsresurrectsDsweztermsZs",
		"httpsCssZssZsgithubsDscomsZschrisgvesZsresurrectsDswezterm",
		"httpsCssZssZsgithubsDscomsZschrisgvesZsresurrectsDsweztermsZs",
		-- MLFlexer
		"httpssCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDswezterm",
		"httpssCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDsweztermsZs",
		"httpsCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDswezterm",
		"httpsCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDsweztermsZs",
	}
	for _, path in ipairs(paths) do
		for _, plugin in ipairs(wezterm.plugin.list()) do
			if plugin.component == path then
				return plugin.plugin_dir
			end
		end
	end
	wezterm.log_error("Could not find plugin directory")
end

--- adds the wezterm plugin directory to the lua path
local function enable_sub_modules()
	package.path = package.path .. ";" .. get_require_path() .. separator .. "plugin" .. separator .. "?.lua"
end

local function init()
	-- enable_sub_modules()
	local opts = {
		auto = true,
		keywords = { "github", "chrisgve", "resurrect", "wezterm" },
	}
	_ = dev.setup(opts)

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
