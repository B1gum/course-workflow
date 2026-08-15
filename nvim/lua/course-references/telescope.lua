local M = {}

local client = require("course-references.zotero")

local function notify_error(message)
    vim.notify("References: " .. tostring(message), vim.log.levels.ERROR)
end

local function current_entry()
    return require("telescope.actions.state").get_selected_entry()
end

local function selected_entries(prompt_bufnr)
    local action_state = require("telescope.actions.state")
    local picker = action_state.get_current_picker(prompt_bufnr)
    local selected = picker:get_multi_selection()

    if #selected == 0 then
        local current = action_state.get_selected_entry()
        if current then
            selected = { current }
        end
    end

    -- Telescope does not promise multi-selection iteration order. Use the
    -- stable Zotero result order so one multi-citation is deterministic.
    table.sort(selected, function(a, b)
        local ai = a.value and a.value.index or math.huge
        local bi = b.value and b.value.index or math.huge
        return ai < bi
    end)

    return selected
end

local function restore_window(position)
    if vim.api.nvim_win_is_valid(position.winid)
        and vim.api.nvim_win_get_buf(position.winid) == position.bufnr then
        vim.api.nvim_set_current_win(position.winid)
        return position.winid
    end

    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(winid)
            and vim.api.nvim_win_get_buf(winid) == position.bufnr then
            vim.api.nvim_set_current_win(winid)
            return winid
        end
    end

    return nil
end

local function insert_citation(position, keys)
    if not position or #keys == 0 then
        return
    end

    if not vim.api.nvim_buf_is_valid(position.bufnr) then
        notify_error("the original buffer no longer exists")
        return
    end

    if not vim.bo[position.bufnr].modifiable then
        notify_error("the original buffer is not modifiable")
        return
    end

    local row = position.cursor[1] - 1
    local col = position.cursor[2]
    local text = "\\cite{" .. table.concat(keys, ",") .. "}"

    vim.api.nvim_buf_set_text(position.bufnr, row, col, row, col, { text })
    local winid = restore_window(position)

    if winid then
        vim.api.nvim_win_set_cursor(winid, { row + 1, col + #text })
    end
end

local function open_reference(entry)
    if not entry or not entry.value or not entry.value.itemKey then
        return
    end

    client.open_reference(entry.value.itemKey, function(err, result)
        if err then
            notify_error(err)
            return
        end

        if result and result.opened == "zotero" and result.reason then
            vim.notify(result.reason, vim.log.levels.WARN)
        end
    end)
end

local function open_zotero(entry)
    if not entry or not entry.value or not entry.value.itemKey then
        return
    end

    client.open_zotero_item(entry.value.itemKey, function(err)
        if err then
            notify_error(err)
        end
    end)
end

local function copy_key(entry)
    local key = entry and entry.value and entry.value.citationKey

    if not key or key == "" then
        return
    end

    vim.fn.setreg("+", key)
    vim.notify("Copied citation key: " .. key, vim.log.levels.INFO)
end

function M.pick(items, options)
    options = options or {}

    if type(items) ~= "table" or #items == 0 then
        vim.notify("No references found in this scope", vim.log.levels.INFO)
        return
    end

    local ok = pcall(require, "telescope")
    if not ok then
        notify_error("Telescope is required for reference search")
        return
    end

    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")

    pickers.new({}, {
        prompt_title = options.title or "References",
        finder = finders.new_table({
            results = items,
            entry_maker = function(ref)
                local author = ref.author or "Unknown"
                local year = ref.year or "n.d."
                local title = ref.title or "Untitled"
                local key = ref.citationKey or "?"

                return {
                    value = ref,
                    display = string.format(
                        "%s · %s  %s  [%s]",
                        author,
                        year,
                        title,
                        key
                    ),
                    ordinal = table.concat({ author, year, title, key }, " "),
                }
            end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                if options.mode == "open" then
                    local entry = current_entry()
                    actions.close(prompt_bufnr)
                    open_reference(entry)
                    return
                end

                local selected = selected_entries(prompt_bufnr)
                local keys = {}

                for _, entry in ipairs(selected) do
                    local key = entry.value and entry.value.citationKey
                    if key and key ~= "" then
                        table.insert(keys, key)
                    end
                end

                actions.close(prompt_bufnr)
                insert_citation(options.position, keys)
            end)

            for _, mode in ipairs({ "i", "n" }) do
                map(mode, "<Tab>", actions.toggle_selection)
                map(mode, "<C-o>", function()
                    open_reference(current_entry())
                end)
                map(mode, "<C-z>", function()
                    open_zotero(current_entry())
                end)
                map(mode, "<C-y>", function()
                    copy_key(current_entry())
                end)
            end

            return true
        end,
    }):find()
end

return M
