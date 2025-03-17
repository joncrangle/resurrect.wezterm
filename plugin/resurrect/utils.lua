local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

local utils = {}

utils.is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
utils.is_mac = (wezterm.target_triple == "x86_64-apple-darwin" or wezterm.target_triple == "aarch64-apple-darwin")
utils.separator = utils.is_windows and "\\" or "/"

-- Helper function to escape pattern special characters
-- function utils.escape_pattern(str)
-- 	return str:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
-- end

-- Helper function to remove formatting sequence in strings
---@param str string
---@return string
function utils.strip_format(str)
	local clean_str = str:gsub(string.char(27) .. "%[[^m]*m", "")
	return clean_str
end

-- getting screen dimensions
---@return number
function utils.get_current_window_width()
	local windows = wezterm.mux.all_windows()
	for _, window in ipairs(windows) do
		local window_id = window:window_id()
		local gui_window = wezterm.gui.gui_window_for_mux_window(window_id)
		if gui_window:is_focused() then
			return window:active_tab():get_size().cols
		end
	end
	return 80
end

-- replace the center of a string with another string
---@param str string string to be modified
---@param len number length to be removed from the middle of str
---@param pad string string that must be inserted in place of the missing part of str
function utils.replace_center(str, len, pad)
	local mid = math.floor(#str / 2)
	local start = mid - math.floor(len / 2)
	return str:sub(1, start) .. pad .. str:sub(start + len + 1)
end

return utils
