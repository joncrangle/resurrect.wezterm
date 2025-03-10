local wezterm = require("wezterm")

local pub = {}

local plugin_dir

local plugin_name = "resurrect"

--- checks if the user is on windows
local is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
local separator = is_windows and "\\" or "/"

--- Checks if the plugin directory exists
--- @return boolean
local function directory_exists(path)
	local success, result = pcall(wezterm.read_dir, plugin_dir .. path)
	return success and result
end

--- Returns the name of the package, used when requiring modules
--- @return string
local function get_require_path()
	local result = ""
	for _, plugin in ipairs(wezterm.plugin.list()) do
		if plugin.component:find(plugin_name) then
			result = plugin.plugin_dir
		end
	end
	print("Require path: ", result)
	return result
end

--- adds the wezterm plugin directory to the lua path
local function enable_sub_modules()
	plugin_dir = get_require_path()
	package.path = package.path .. ";" .. plugin_dir .. separator .. "plugin" .. separator .. "?.lua"
end

local function init()
	enable_sub_modules()

	require("resurrect.state_manager").change_state_save_dir(
		plugin_dir .. separator .. get_require_path() .. separator .. "state" .. separator
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
