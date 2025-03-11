local wezterm = require("wezterm")
local pub = {}

---@alias fmt_fun fun(label: string): string
---@alias fuzzy_load_opts {title: string, description: string, fuzzy_description: string, is_fuzzy: boolean,
---ignore_workspaces: boolean, ignore_tabs: boolean, ignore_windows: boolean, fmt_window: fmt_fun, fmt_workspace: fmt_fun,
---fmt_tab: fmt_fun, fmt_date: fmt_fun, show_state_with_date: boolean, date_format: string }

---Returns default fuzzy loading options
---@return fuzzy_load_opts
function pub.get_default_fuzzy_load_opts()
	return {
		title = "Load State",
		description = "Select State to Load and press Enter = accept, Esc = cancel, / = filter",
		fuzzy_description = "Search State to Load: ",
		is_fuzzy = true,
		ignore_workspaces = false,
		ignore_windows = false,
		ignore_tabs = false,
		date_format = "%d-%m-%Y %H:%M:%S",
		show_state_with_date = false,
		fmt_date = function(date)
			return wezterm.format({
				{ Foreground = { AnsiColor = "White" } },
				{ Text = date },
			})
		end,
		fmt_workspace = function(label)
			return wezterm.format({
				{ Foreground = { AnsiColor = "Green" } },
				{ Text = "󱂬 : " .. label:gsub("%.json$", "") },
			})
		end,
		fmt_window = function(label)
			return wezterm.format({
				{ Foreground = { AnsiColor = "Yellow" } },
				{ Text = " : " .. label:gsub("%.json$", "") },
			})
		end,
		fmt_tab = function(label)
			return wezterm.format({
				{ Foreground = { AnsiColor = "Red" } },
				{ Text = "󰓩 : " .. label:gsub("%.json$", "") },
			})
		end,
	}
end

---A fuzzy finder to restore saved state
---@param window MuxWindow
---@param pane Pane
---@param callback fun(id: string, label: string, save_state_dir: string)
---@param opts fuzzy_load_opts?
function pub.fuzzy_load(window, pane, callback, opts)
	wezterm.emit("resurrect.fuzzy_loader.fuzzy_load.start", window, pane)
	local state_files = {}

	if opts == nil then
		opts = pub.get_default_fuzzy_load_opts()
	else
		-- Merge user opts with defaults
		local default_opts = pub.get_default_fuzzy_load_opts()
		for k, v in pairs(default_opts) do
			if opts[k] == nil then
				opts[k] = v
			end
		end
	end

	local folder = require("resurrect.state_manager").save_state_dir

	local function def_insert_choices(type, fmt)
		for _, file in ipairs(wezterm.glob("*", folder .. Separator .. type)) do
			local label
			local id = type .. Separator .. file

			if fmt then
				label = fmt(file)
			else
				label = file
			end
			table.insert(state_files, { id = id, label = label })
		end
	end

	local function execute(type)
		-- Command-line recipe based on OS
		local path = folder .. type
		local cmd
		if Is_windows then
			cmd = "powershell -Command \"Get-ChildItem -Path '"
				.. path
				.. '\' | ForEach-Object { "$($_.LastWriteTime.ToFileTimeUtc()) $($_.Name)" }"'
		elseif Is_mac then
			cmd = 'stat -f "%m %N" ' .. path .. "/*"
		else -- last option: Linux-like
			cmd = 'ls -l --time-style=+"%s" ' .. path .. " | awk '{print $6,$7,$9}'"
		end

		-- Execute the command and capture stdout
		local handle = io.popen(cmd)
		if handle == nil then
			wezterm.emit("resurrect.error", "Could not open process: " .. cmd)
			return ""
		end

		local stdout = handle:read("*a")
		if stdout == nil then
			wezterm.emit("resurrect.error", "No output when running: " .. cmd)
			return ""
		end

		handle:close()
		return stdout
	end

	local function insert_choices()
		local files = {}
		local max_length = 0

		-- collect all the included files
		local types = { "workspace", "window", "tab" }
		for _, type in ipairs(types) do
			local include = not opts[string.format("ignore_%ss", type)]
			if include then
				local fmt = opts[string.format("fmt_%s", type)]

				local stdout = execute(type)

				if stdout == "" then
					def_insert_choices(type, fmt)
				else
					-- Parse the stdout and construct the file table
					for line in stdout:gmatch("[^\n]+") do
						local epoch, file = line:match("(%d+)%s+(.+)")
						if epoch and file then
							local filename, ext = file:match("^.*" .. Separator .. "(.+)%.(.*)$")
							local date = os.date(opts.date_format, tonumber(epoch))
							max_length = math.max(max_length, #filename)
							table.insert(files, {
								id = type .. Separator .. filename .. "." .. ext,
								filename = filename,
								date = date,
								fmt = fmt,
							})
						end
					end
				end
			end
		end

		for _, file in ipairs(files) do
			local padding = " "
			if #file.filename < max_length then
				padding = padding .. string.rep(".", max_length - #file.filename - 1) .. padding
			end
			local label = ""
			if file.fmt then
				label = file.fmt(file.filename .. padding)
			else
				label = file.filename .. padding
			end
			if opts.fmt_date then
				label = label .. " " .. opts.fmt_date(file.date)
			else
				label = label .. " " .. file.date
			end
			table.insert(state_files, { id = file.id, label = label })
		end
	end

	if opts.show_state_with_date then
		insert_choices()
	else
		if not opts.ignore_workspaces then
			def_insert_choices("workspace", opts.fmt_workspace)
		end

		if not opts.ignore_windows then
			def_insert_choices("window", opts.fmt_window)
		end

		if not opts.ignore_tabs then
			def_insert_choices("tab", opts.fmt_tab)
		end
	end

	window:perform_action(
		wezterm.action.InputSelector({
			action = wezterm.action_callback(function(_, _, id, label)
				if id and label then
					callback(id, label, require("resurrect.state_manager").save_state_dir)
				end
				wezterm.emit("resurrect.fuzzy_loader.fuzzy_load.finished", window, pane)
			end),
			title = opts.title,
			description = opts.description,
			fuzzy_description = opts.fuzzy_description,
			choices = state_files,
			fuzzy = opts.is_fuzzy,
		}),
		pane
	)
end

return pub
