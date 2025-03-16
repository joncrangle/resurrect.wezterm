local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

local utils = {}

utils.is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
utils.is_mac = (wezterm.target_triple == "x86_64-apple-darwin" or wezterm.target_triple == "aarch64-apple-darwin")
utils.separator = utils.is_windows and "\\" or "/"

-- Helper function to escape pattern special characters
function utils.escape_pattern(str)
	return str:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

-- Helper function to remove formatting sequence in strings
function utils.strip_format(str)
	return str:gsub(string.char(27) .. "%[[^m]*m")
end

return utils
