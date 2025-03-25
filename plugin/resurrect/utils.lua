local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

local utils = {}

utils.is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
utils.is_mac = (wezterm.target_triple == "x86_64-apple-darwin" or wezterm.target_triple == "aarch64-apple-darwin")
utils.separator = utils.is_windows and "\\" or "/"

-- Helper function to remove formatting sequence in strings
---@param str string
---@return string
function utils.strip_format(str)
	local clean_str, _ = str:gsub(string.char(27) .. "%[[^m]*m", "")
	return clean_str
end

-- getting screen dimensions
---@return number
function utils.get_current_window_width()
	local windows = wezterm.gui.gui_windows()
	for _, window in ipairs(windows) do
		if window:is_focused() then
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
	local mid = #str // 2
	local start = mid - (len // 2)
	return str:sub(1, start) .. pad .. str:sub(start + len + 1)
end

-- returns the length of a utf8 string
---@param str string
---@return number
function utils.utf8len(str)
	local _, len = str:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
	return len
end

-- Write a file with the content of a string
---@param file_path string full filename
---@param str string string to be Write
---@return boolean success result
---@return string|nil error
function utils.write_file(file_path, str)
	local suc, err = pcall(function()
		local handle = io.open(file_path, "w+")
		if not handle then
			error("Could not open file: " .. file_path)
		end
		handle:write(str)
		handle:flush()
		handle:close()
	end)
	return suc, err
end

-- Read a file and return its content
---@param file_path string full filename
---@return string content file content
---@return boolean success result
---@return string|nil error
function utils.read_file(file_path)
	local stdout
	local suc, err = pcall(function()
		local handle = io.open(file_path, "r")
		if not handle then
			error("Could not open file: " .. file_path)
		end
		stdout = handle:read("*a")
		handle:close()
	end)
	if suc then
		return stdout, true
	else
		return "", suc, err
	end
end

-- Execute a cmd and return its stdout
---@param cmd string command
---@return string stdout command result
---@return boolean success result
---@return string|nil error
function utils.execute(cmd)
	local stdout
	local suc, err = pcall(function()
		local handle = io.popen(cmd)
		if not handle then
			error("Could not open process: " .. cmd)
		end
		stdout = handle:read("*a")
		if stdout == nil then
			error("Error running process: " .. cmd)
		end
		handle:close()
	end)
	if suc then
		return stdout, true
	else
		return "", suc, err
	end
end

return utils
