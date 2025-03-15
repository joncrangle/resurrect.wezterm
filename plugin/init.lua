local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

local pub = {}

local source_name = "file"
local plugin_name = "resurrectsDswezterm"
local dev = false

--- checks if the user is on Windows or MacOS and create globals
local is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
local is_mac = (wezterm.target_triple == "x86_64-apple-darwin" or wezterm.target_triple == "aarch64-apple-darwin")
local separator = is_windows and "\\" or "/"

--- Checks if the plugin directory exists
--- @return boolean
local function directory_exists(path)
	local success, result = pcall(wezterm.read_dir, path)
	return success and result
end

--- Returns the name of the package during development, used when requiring modules
--- @return string
local function get_require_dev_path()
	local result = ""
	for _, plugin in ipairs(wezterm.plugin.list()) do
		if plugin.component:find(plugin_name) and (plugin.component:find(source_name) or source_name == "") then
			result = plugin.plugin_dir
		end
	end
	return result
end

--- Returns the name of the package, used when requiring modules
--- @return string
local function get_require_path(plugin_base_dir)
	plugin_base_dir = plugin_base_dir .. separator
	print(plugin_base_dir)
	local path
	local folders = {
		"httpssCssZssZsgithubsDscomsZschrisgvesZsresurrectsDswezterm", -- sources with https
		"httpssCssZssZsgithubsDscomsZschrisgvesZsresurrectsDsweztermsZs",
		"httpsCssZssZsgithubsDscomsZschrisgvesZsresurrectsDswezterm", -- source with http
		"httpsCssZssZsgithubsDscomsZschrisgvesZsresurrectsDsweztermsZs",
		"httpssCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDswezterm", -- sources with https
		"httpssCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDsweztermsZs",
		"httpsCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDswezterm", -- source with http
		"httpsCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDsweztermsZs",
	}
	-- check which variant is installed
	for _, folder in ipairs(folders) do
		path = plugin_base_dir .. folder
		print(path)
		if directory_exists(path) then
			return path
		end
	end
	-- last resort we try the development folder
	path = get_require_dev_path()
	if directory_exists(path) then
		return path
	end
	-- at this point no folder was found
	return ""
end

--- adds the resurrect.wezterm plugin directory to the lua path and return its path
local function enable_sub_modules()
	local plugin_dir
	if dev then
		plugin_dir = get_require_dev_path()
	else
		local plugin_base_dir = wezterm.plugin.list()[1].plugin_dir:gsub(separator .. "[^" .. separator .. "]*$", "")
		plugin_dir = get_require_path(plugin_base_dir)
		print(plugin_dir)
	end
	if plugin_dir ~= "" then
		local path = plugin_dir .. separator .. "plugin" .. separator .. "?.lua"
		print(path)
		package.path = package.path .. ";" .. path
	end
	return plugin_dir
end

local function init()
	local plugin_dir = enable_sub_modules()

	if plugin_dir == "" then
		wezterm.emit("resurrect.init_error", "Plugin folder not found")
		error("Could not find the plugin folder")
	else
		require("resurrect.state_manager").change_state_save_dir(plugin_dir .. separator .. "state" .. separator)

		-- Export submodules
		pub.workspace_state = require("resurrect.workspace_state")
		pub.window_state = require("resurrect.window_state")
		pub.tab_state = require("resurrect.tab_state")
		pub.fuzzy_loader = require("resurrect.fuzzy_loader")
		pub.state_manager = require("resurrect.state_manager")
	end
end

init()

return pub
