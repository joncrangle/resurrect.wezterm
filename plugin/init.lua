local wezterm = require("wezterm")

local pub = {}

local plugin_dir

local plugin_name = "resurrectsDswezterm"

--- checks if the user is on Windows or MacOS
Is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
Is_mac = (wezterm.target_triple == "x86_64-apple-darwin" or wezterm.target_triple == "aarch64-apple-darwin")
Separator = Is_windows and "\\" or "/"

--- Returns the name of the package, used when requiring modules
--- @return string
local function get_require_path()
	local result = ""
	for _, plugin in ipairs(wezterm.plugin.list()) do
		if plugin.component:find(plugin_name) then
			result = plugin.plugin_dir
		end
	end
	return result
end

--- adds the wezterm plugin directory to the lua path
local function enable_sub_modules()
	plugin_dir = get_require_path()
	package.path = package.path .. ";" .. plugin_dir .. Separator .. "plugin" .. Separator .. "?.lua"
end

local function init()
	enable_sub_modules()

	require("resurrect.state_manager").change_state_save_dir(
		plugin_dir .. Separator .. get_require_path() .. Separator .. "state" .. Separator
	)

	-- Export submodules
	pub.workspace_state = require("resurrect.workspace_state")
	pub.window_state = require("resurrect.window_state")
	pub.tab_state = require("resurrect.tab_state")
	pub.fuzzy_loader = require("resurrect.fuzzy_loader")
	pub.state_manager = require("resurrect.state_manager")
end

init()

return pub
