local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")
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

	-- Optimized recursive JSON file finder for all platforms
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
	end

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

		-- getting screen dimensions
		local width = os.getenv("COLUMNS")
		wezterm.log_info("Columns:", width)

		-- Format and add files to state_files list
		local types = { "workspace", "window", "tab" }
		for _, type in ipairs(types) do
			local include = not opts[string.format("ignore_%ss", type)]
			if include then
				for _, file in ipairs(files) do
					if file.type == type then
						local label = ""

						if opts.show_state_with_date then
							local padding = " "
							if #file.filename < max_length then
								padding = padding .. string.rep(".", max_length - #file.filename - 1) .. " "
							end

							if file.fmt then
								label = file.fmt(file.filename .. padding)
							else
								label = file.filename .. padding
							end

							local date = os.date(opts.date_format, tonumber(file.epoch))
							if opts.fmt_date then
								label = label .. " " .. opts.fmt_date(date)
							else
								label = label .. " " .. date
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
