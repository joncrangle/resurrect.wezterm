local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")
local file_io = require("resurrect.file_io")
local utf8len = utils.utf8len
local pub = {}

-- Cached values in the module
local fmt_cost = {}

---@alias fmt_fun fun(label: string): string
---@alias fuzzy_load_opts {title: string, description: string, fuzzy_description: string, is_fuzzy: boolean,
---ignore_workspaces: boolean, ignore_tabs: boolean, ignore_windows: boolean, fmt_window: fmt_fun, fmt_workspace: fmt_fun,
---fmt_tab: fmt_fun, fmt_date: fmt_fun, show_state_with_date: boolean, date_format: string, ignore_screen_width: boolean,
---name_truncature: string, min_filename_size: number}

---Default fuzzy loading options
---@return fuzzy_load_opts
pub.default_fuzzy_load_opts = {
	title = "Load State",
	description = "Select State to Load and press Enter = accept, Esc = cancel, / = filter",
	fuzzy_description = "Search State to Load: ",
	is_fuzzy = true,
	ignore_workspaces = false,
	ignore_windows = false,
	ignore_tabs = false,
	ignore_screen_width = true,
	date_format = "%d-%m-%Y %H:%M:%S",
	show_state_with_date = false,
	name_truncature = " " .. wezterm.nerdfonts.cod_ellipsis .. "  ",
	min_filename_size = 10,
	fmt_date = function(date)
		return wezterm.format({
			{ Foreground = { AnsiColor = "White" } },
			{ Text = date },
		})
	end,
	fmt_workspace = function(label)
		return wezterm.format({
			{ Foreground = { AnsiColor = "Green" } },
			{ Text = "󱂬 : " .. label:gsub("(.*)%.json(.*)", "%1%2") },
		})
	end,
	fmt_window = function(label)
		return wezterm.format({
			{ Foreground = { AnsiColor = "Yellow" } },
			{ Text = " : " .. label:gsub("(.*)%.json(.*)", "%1%2") },
		})
	end,
	fmt_tab = function(label)
		return wezterm.format({
			{ Foreground = { AnsiColor = "Red" } },
			{ Text = "󰓩 : " .. label:gsub("(.*)%.json(.*)", "%1%2") },
		})
	end,
}

-- Optimized recursive JSON file finder for all platforms
---@param base_path string starting path from which the recursive search takes place
---@return string|nil
local function find_json_files_recursive(base_path)
	local cmd
	local stdout
	local suc, err

	if utils.is_windows then
		-- For Windows, use VBS for better performance and truly invisible execution
		local temp_vbs = os.tmpname() .. ".vbs"
		local temp_out = os.tmpname() .. ".txt"

		local vbs_script = string.format(
			[[
                Set fso = CreateObject("Scripting.FileSystemObject")
                Set outFile = fso.CreateTextFile("%s", True)
                
                Sub ProcessFolder(folderPath)
                    On Error Resume Next
                    Set folder = fso.GetFolder(folderPath)
                    If Err.Number <> 0 Then
                        Exit Sub
                    End If
                    
                    ' Process files in current folder
                    For Each file in folder.Files
                        If LCase(fso.GetExtensionName(file.Name)) = "json" Then
                            epoch = DateDiff("s", "01/01/1970 00:00:00", file.DateLastModified)
                            outFile.WriteLine(epoch & " " & file.Path)
                        End If
                    Next
                    
                    ' Process subfolders recursively
                    For Each subFolder in folder.SubFolders
                        ProcessFolder(subFolder.Path)
                    Next
                End Sub
                
                ProcessFolder("%s")
                outFile.Close
            ]],
			temp_out:gsub("\\", "\\\\"),
			base_path:gsub("\\", "\\\\")
		)

		-- Create a second VBS script that will run the first one invisibly
		local launcher_vbs = os.tmpname() .. "_launcher.vbs"
		local launcher_script = string.format(
			[[
                Set WshShell = CreateObject("WScript.Shell")
                WshShell.Run "wscript.exe //nologo %s", 0, True
            ]],
			temp_vbs
		)

		-- Write the scripts
		suc, err = file_io.write_file(temp_vbs, vbs_script)
		if not suc then
			wezterm.emit("resurrect.error", err)
			return
		end

		suc, err = file_io.write_file(launcher_vbs, launcher_script)
		if not suc then
			wezterm.emit("resurrect.error", err)
			os.remove(temp_vbs) -- by the time we are here the `temb_vbs` file already exists so we should clean up
			return
		end
		-- Execute using launcher (completely hidden)
		os.execute("wscript.exe //nologo " .. launcher_vbs)

		suc, stdout = file_io.read_file(temp_out)

		-- Clean up temp files
		os.remove(temp_vbs)
		os.remove(launcher_vbs)
		os.remove(temp_out)

		if suc then
			return stdout
		else
			wezterm.emit("resurrect.error", stdout)
			return
		end
	elseif utils.is_mac then
		-- macOS recursive find command for JSON files
		cmd = 'find "' .. base_path .. '" -type f -name "*.json" -print0 | xargs -0 stat -f "%m %N"'
	else
		-- Linux optimized recursive find command for JSON files
		cmd = string.format(
			'find "$(realpath %q)" -type f -name "*.json" -printf "%%T@ %%p\\n" | awk \'{split($1, a, "."); print a[1], $2}\'',
			base_path
		)
	end

	-- Execute the command and capture stdout for non-Windows
	suc, stdout = utils.execute(cmd)

	if suc then
		return stdout
	else
		wezterm.emit("resurrect.error", stdout)
		return
	end
end

-- build a table with the output of the file finder function
---@param stdout string|nil
---@param opts table
---@return table
local function insert_choices(stdout, opts)
	-- pre-calculation of formatting cost
	local types = { "workspace", "window", "tab" }
	local state_files = {}
	local files = {
		workspace = {},
		window = {},
		tab = {},
	}
	local max_length = 0
	local max_length_raw = 0

	if stdout == nil then
		return state_files
	end

	-- Parse the stdout and construct the file table
	for line in stdout:gmatch("[^\n]+") do
		local epoch, type, file = line:match("%s*(%d+)%s+.+[/\\]([^/\\]+)[/\\]([^/\\]+%.json)$")
		-- epoch in this case represents the last modified date/time according to the OS
		-- For Unix/POSIX Epoch is counted from January 1st, 1970 0 UTC
		-- MacOS it is from January 1st, 1904 0 UTC
		-- Windows NTFS (up to Win 11) it is from January 1st, 1601 0 UTC
		-- The function `os.date()` used later on will convert the date according to the host OS
		if epoch and file and type and not opts[string.format("ignore_%ss", type)] then
			-- consider the "cost" of the formatting of the filename, i.e., if the format function adds characters
			-- to the visible part of the file section, we test the three possible formatter to get the highest cost
			-- we use a real entry instead of an empty string to prevent formatting error if the format function has
			-- expectations to work correctly
			-- This prevent from having to format every filename, instead we can take the filename length and then
			-- the cost of formatting per type
			--
			if next(fmt_cost) == nil then
				fmt_cost.workspace = 0 -- cost of formatting the workspace name
				fmt_cost.window = 0 -- cost of formatting the window name
				fmt_cost.tab = 0 -- cost of formatting the tab
				fmt_cost.str_date = 0 -- cost of date as a string
				fmt_cost.fmt_date = 0 -- cost of formatting the date
				-- Calculate the cost for formatting the filename
				local len = utf8len(file)
				for _, t in ipairs(types) do
					if not opts[string.format("ignore_%ss", t)] then
						local fmt = opts[string.format("fmt_%s", t)]
						if fmt then
							fmt_cost[t] = utf8len(fmt(file)) - len
							wezterm.log_info(t, fmt(file))
						end
					end
				end
				-- Calculate the cost for formatting the date
				if opts.show_state_with_date then
					local str_date = os.date(opts.date_format, tonumber(epoch))
					fmt_cost.str_date = utf8len(str_date)
					if opts.fmt_date then
						fmt_cost.fmt_date = utf8len(utils.strip_format_esc_seq(opts.fmt_date(str_date)))
							- fmt_cost.str_date
					end
				end
				wezterm.log_info(fmt_cost)
			end

			-- Calculating the maximum file length
			local filename_len = utf8len(file) -- we keep this so we don't have to measure it later
			max_length = math.max(max_length, filename_len + fmt_cost[type])
			max_length_raw = math.max(max_length_raw, filename_len)

			-- collecting all relevant information about the file
			local fmt = opts[string.format("fmt_%s", type)]
			table.insert(files[type], {
				id = type .. utils.separator .. file,
				filename = file,
				filename_len = filename_len,
				epoch = epoch,
				fmt = fmt,
			})
		end
	end

	-- During the selection view, InputSelector will take 4 characters on the left and 2 characters
	-- on the right of the window
	local width = utils.get_current_window_width() - 4
	local must_shrink = nil

	wezterm.log_info("screen width", width)
	wezterm.log_info("max length", max_length)
	wezterm.log_info("max length raw", max_length_raw)
	wezterm.log_info("total cost ws", max_length_raw + fmt_cost.workspace + fmt_cost.str_date + fmt_cost.fmt_date)
	wezterm.log_info("total cost wn", max_length_raw + fmt_cost.window + fmt_cost.str_date + fmt_cost.fmt_date)
	wezterm.log_info("total cost tb", max_length_raw + fmt_cost.tab + fmt_cost.str_date + fmt_cost.fmt_date)

	if opts.ignore_screen_width then
		must_shrink = false
	end

	-- Add files to state_files list and apply the formatting functions
	for _, type in ipairs(types) do
		for _, file in ipairs(files[type]) do
			-- determines whether we need to manage content to fit the screen, we run this only once
			local overflow_chars = 0
			if must_shrink == nil then
				local estimated_length = max_length + fmt_cost.str_date + fmt_cost.fmt_date
				if estimated_length > width then
					overflow_chars = estimated_length - width
					must_shrink = true
				else
					must_shrink = false
				end
			end

			file.date = ""
			file.label = ""
			file.dots = ""

			file.label = file.filename

			if opts.show_state_with_date then
				file.date = os.date(opts.date_format, tonumber(file.epoch))
				if opts.fmt_date then
					file.date = opts.fmt_date(file.date)
				end

				file.dots = string.rep(
					".",
					math.max( -- ensures that we don't have a negative length
						0,
						math.min( -- the length of the dotted line is bound by the number of overflow_chars we might have to save
							max_length - file.filename_len - 1,
							max_length - file.filename_len - 1 - overflow_chars
						)
					)
				)
				-- we correct the number of overflow_chars with what could be reduced from the dots
				-- max_length - file.filename_len - 1 is the length of dots we should have had if we had
				-- enough space
				overflow_chars = overflow_chars - ((max_length - file.filename - 1) - #file.dots)
				file.dots = " " .. file.dots .. " " -- adding the padding around the dots
			end

			-- regardless of date or no date now we are either done with the overflow_chars or we still have to reduce the
			-- number of chars of the filename
			local str_pad = opts.name_truncature or "..."
			local pad_len = utf8len(str_pad)
			local min_filename_len = opts.min_filename_size or 10 -- minimum size of the filename to remain decypherable

			local reduction = file.filename_len
				- math.max(min_filename_len, file.filename_len + pad_len - overflow_chars)
			file.label = utils.replace_center(file.label, reduction, str_pad)

			-- and now everything comes together
			file.label = file.label .. file.dots
			if file.fmt then
				file.label = file.fmt(file.label)
			end
			file.label = file.label .. file.date

			table.insert(state_files, { id = file.id, label = file.label })
		end
	end
	return state_files
end

---A fuzzy finder to restore saved state
---@param window MuxWindow
---@param pane Pane
---@param callback fun(id: string, label: string, save_state_dir: string)
---@param opts fuzzy_load_opts?
function pub.fuzzy_load(window, pane, callback, opts)
	wezterm.emit("resurrect.fuzzy_loader.fuzzy_load.start", window, pane)

	opts = utils.tbl_deep_extend("force", pub.default_fuzzy_load_opts, opts or {})

	local folder = require("resurrect.state_manager").save_state_dir

	-- Always use the recursive search function
	local stdout = find_json_files_recursive(folder)

	-- build the choice list for the InputSelector
	local state_files = insert_choices(stdout, opts)

	if #state_files == 0 then
		wezterm.emit("resurrect.error", "No existing state files to select")
	end

	-- even if the list is empty, user experience is better if we show an empty list
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
	fmt_cost = {} -- we need to reinitialize this since next call might be with different options, including formatting
end

return pub
