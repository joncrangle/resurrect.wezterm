local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")
local pub = {}

---@alias fmt_fun fun(label: string): string
---@alias fuzzy_load_opts {title: string, description: string, fuzzy_description: string, is_fuzzy: boolean,
---ignore_workspaces: boolean, ignore_tabs: boolean, ignore_windows: boolean, fmt_window: fmt_fun, fmt_workspace: fmt_fun,
---fmt_tab: fmt_fun, fmt_date: fmt_fun, show_state_with_date: boolean, date_format: string, ignore_screen_width: boolean }

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
		ignore_screen_width = true,
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

	-- Optimized recursive JSON file finder for all platforms
	---@param base_path string starting path from which the recursive search takes place
	---@return string
	local function find_json_files_recursive(base_path)
		local cmd

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
			local handle = io.open(temp_vbs, "w")
			if handle == nil then
				wezterm.emit("resurrect.error", "Could not create temporary Windows process")
				return ""
			end
			handle:write(vbs_script)
			handle:close()

			handle = io.open(launcher_vbs, "w")
			if handle == nil then
				wezterm.emit("resurrect.error", "Could not create launcher script")
				return ""
			end
			handle:write(launcher_script)
			handle:close()

			-- Execute using launcher (completely hidden)
			os.execute("wscript.exe //nologo " .. launcher_vbs)

			-- Read results
			handle = io.open(temp_out, "r")
			if handle == nil then
				wezterm.emit("resurrect.error", "Could not open temporary Windows process output")
				return ""
			end

			local stdout = handle:read("*a")
			if stdout == nil then
				wezterm.emit("resurrect.error", "The Windows process had no output")
				return ""
			end

			handle:close()

			-- Clean up temp files
			os.remove(temp_vbs)
			os.remove(launcher_vbs)
			os.remove(temp_out)

			return stdout
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

		if not utils.is_windows then
			-- Execute the command and capture stdout for non-Windows
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
		return ""
	end

	-- build a table with the output of the file finder function
	local function insert_choices()
		local files = {}
		local max_length = 0

		local stdout = find_json_files_recursive(folder)
		if stdout == "" then
			return
		else
			-- Parse the stdout and construct the file table
			for line in stdout:gmatch("[^\n]+") do
				local epoch, type, file = line:match("%s*(%d+)%s+.+[/\\]([^/\\]+)[/\\]([^/\\]+%.json)$")
				if epoch and file and type and type == type then
					-- Calculating the maximum file length
					max_length = math.max(max_length, #file)

					-- Collecting all relevant information about the file
					local fmt = opts[string.format("fmt_%s", type)]
					table.insert(files, {
						id = type .. utils.separator .. file,
						filename = file,
						epoch = epoch,
						fmt = fmt,
						type = type,
					})
					-- end
				end
			end
		end

		-- Format the label given the available screen width, starting with the padding and then reducing the
		-- filename itself up to a minimum length, then the date can be reduced as a last resort but otherwise
		-- nothing else can be done because the screen is too small
		---@param win_width number width of the window
		---@param file table file package with all necessary information
		---@return string
		local function format_label(win_width, file)
			local min_filename_len = 10 -- minimum size of the filename to remain decypherable
			local str_pad = " " .. wezterm.nerdfonts.cod_ellipsis .. "  "
			local label = {
				filename_raw = "",
				filename_len = 0,
				separator = "",
				padding_raw = "",
				padding_len = 0,
				name_raw = "",
				name_fmt = "",
				name_len = 0,
				date_raw = "",
				date_fmt = "",
				date_len = 0,
			}
			local result = ""
			-- fill raw values and run a dry run of the formatting to measure the resulting length
			label.filename_raw = file.filename
			label.filename_len = #label.filename_raw
			if opts.show_state_with_date then
				label.separator = " "
				if #file.filename < max_length then
					label.padding_raw = string.rep(".", max_length - #file.filename - 1)
					label.padding_len = #label.padding_raw
				end
				label.date_raw = file.date
				if opts.fmt_date then
					label.date_fmt = opts.fmt_date(label.date_raw)
					label.date_len = #utils.strip_format(label.date_fmt)
				else
					label.date_fmt = label.date_raw
					label.date_len = #label.date_fmt_fmt
				end
			end
			label.name_raw = label.filename_raw .. label.separator .. label.padding_raw .. label.separator
			if file.fmt then
				label.name_fmt = file.fmt(label.name_raw)
				label.name_len = #utils.strip_format(label.name_fmt)
			else
				label.name_fmt = label.name_raw
				label.name_len = #label.name_fmt
			end

			-- check the overall width against the available width, four characters are added to account for those used by wezterm
			-- for selection when not using fuzzy matching and remain, but are blank when using fuzzy matching
			local width = label.name_len + label.date_len + 4
			-- `oversize` is the number of character we should remove
			local oversize = math.min(0, width - win_width)

			if oversize == 0 then
				-- No oversize for this line, thus we keep it as is (though it shouldn't occur when we use this function)
				return label.name_fmt .. label.date_fmt
			else
				-- we need to save a `oversize` character; first check if the padding can be used
				if label.padding_len ~= 0 then
					local new_len = math.max(0, label.padding_len - oversize)
					oversize = oversize - (label.padding_len - new_len) -- update the oversize
					label.padding_raw = string.rep(".", new_len)
				end
				-- we tackle the filename reducing it to a length with a minimum of `min_filename_len`
				if oversize ~= 0 then
					-- new we need to apply the size reduction to the filename, our strategy:
					-- remove the `oversize` from the middle of the filename string and
					-- replace it by an ellipsis nerdfont between two spaces, thus we need to correct that
					oversize = oversize + 4
					-- here we can re-adjust the filename string to fit the available room, but up to a point
					local reduction = label.filename_len - math.max(min_filename_len, label.filename_len - oversize)
					oversize = oversize - reduction
					label.filename_raw = utils.replace_center(label.filename_raw, reduction, str_pad)
				end
				-- do we still have an oversize? we can do something only if we have a date, otherwise we did our best
				if oversize ~= 0 and opts.show_state_with_date then
					local new_len = math.max(0, label.date_len - oversize)
					if new_len == 0 then
						file.date_raw = ""
					else
						file.date_raw = file.date_raw:sub(1, new_len)
					end
				end
			end

			-- now we can format and recombine the reduced strings
			result = label.filename_raw .. label.separator .. label.padding_raw .. label.separator
			if file.fmt then
				result = file.fmt(result)
			end
			if opts.show_state_with_date then
				if opts.fmt_date then
					result = result .. label.separator .. opts.fmt_date(label.date_raw)
				else
					result = result .. label.separator .. label.date_raw
				end
			end

			return result
		end

		local width = utils.get_current_window_width()

		local must_shrink = nil

		if opts.ignore_screen_width then
			must_shrink = false
		end

		-- Add files to state_files list and apply the formatting functions
		local types = { "workspace", "window", "tab" }
		for _, type in ipairs(types) do
			local include = not opts[string.format("ignore_%ss", type)]
			if include then
				for _, file in ipairs(files) do
					if file.type == type then
						local label = ""
						if opts.show_state_with_date then
							file.date = os.date(opts.date_format, tonumber(file.epoch))
						else
							file.date = ""
						end

						-- determines whether we need to manage content to fit the screen, we run this only once
						if must_shrink == nil then
							local estimated_length = 0
							-- consider the length of the formatted date section
							if opts.show_state_with_date then
								if opts.fmt_date then
									estimated_length = #utils.strip_format(opts.fmt_date(file.date)) + 2 -- for the separators
								else
									estimated_length = #file.date
								end
							end
							-- consider the "cost" of the formatting of the filename, i.e., if the format function adds characters
							-- to the visible part of the file section, we test the three possible formatter to get the highest cost
							-- we use a real entry instead of an empty string to prevent formatting error if the format function has
							-- expectations to work correctly
							local fmt_cost = 0
							local nominal_length = #file.filename
							if opts.fmt_tab then
								fmt_cost = #utils.strip_format(opts.fmt_tab(file.filename)) - nominal_length
							end
							if opts.fmt_window then
								fmt_cost = math.max(
									fmt_cost,
									#utils.strip_format(opts.fmt_window(file.filename)) - nominal_length
								)
							end
							if opts.fmt_workspace then
								fmt_cost = math.max(
									fmt_cost,
									#utils.strip_format(opts.fmt_workspace(file.filename)) - nominal_length
								)
							end
							-- the longest prompt is derived from the maximum length of the filename plus the cost of the format
							estimated_length = estimated_length + fmt_cost + max_length
							if estimated_length > width then
								must_shrink = true
							else
								must_shrink = false
							end
						end

						if must_shrink then
							-- we must ensure that the line fits within the width of the screen,
							-- thus we invoke `format_label` which will take care of this for us
							-- as smartly as possible
							table.insert(state_files, { id = file.id, label = format_label(width, file) })
						else
							if opts.show_state_with_date then
								if #file.filename < max_length then
									label = " " .. string.rep(".", max_length - #file.filename - 1) .. " "
								else
									label = " "
								end

								if file.fmt then
									label = file.fmt(file.filename .. label)
								else
									label = file.filename .. label
								end

								if opts.fmt_date then
									label = label .. " " .. opts.fmt_date(file.date)
								else
									label = label .. " " .. file.date
								end
							else
								if file.fmt then
									label = file.fmt(file.filename)
								else
									label = file.filename
								end
							end
							table.insert(state_files, { id = file.id, label = label })
						end
					end
				end
			end
		end
	end

	-- Always use the recursive search function
	insert_choices()

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
end

return pub
