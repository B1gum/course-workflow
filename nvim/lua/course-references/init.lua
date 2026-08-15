local M = {}

local client = require("course-references.zotero")
local telescope = require("course-references.telescope")

local setup_done = false

local function notify_error(message)
    vim.notify("References: " .. tostring(message), vim.log.levels.ERROR)
end

local function current_path()
    local path = vim.api.nvim_buf_get_name(0)

    if path == "" then
        return nil
    end

    return vim.fn.fnamemodify(path, ":p")
end

local function capture_position()
    return {
        bufnr = vim.api.nvim_get_current_buf(),
        winid = vim.api.nvim_get_current_win(),
        cursor = vim.api.nvim_win_get_cursor(0),
    }
end

local function search_course(mode)
    local position = capture_position()

    client.search_course({ path = current_path() }, function(err, result)
        if err then
            notify_error(err)
            return
        end

        telescope.pick(result.items or {}, {
            title = mode == "open" and "Open Reference" or "References",
            position = position,
            mode = mode,
        })
    end)
end

function M.search_course()
    search_course("insert")
end

function M.search_all()
    local position = capture_position()

    client.search_all(function(err, result)
        if err then
            notify_error(err)
            return
        end

        telescope.pick(result.items or {}, {
            title = "References · All",
            position = position,
            mode = "insert",
        })
    end)
end

function M.open_reference()
    search_course("open")
end

local function citepage_under_cursor()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local col = cursor[2]
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local start_row = math.max(0, row - 2)
    local end_row = math.min(line_count, row + 3)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)

    if #lines == 0 then
        return nil, "No \\citepage command under the cursor."
    end

    local cursor_offset = 0
    local cursor_line_index = row - start_row + 1

    for index = 1, cursor_line_index - 1 do
        cursor_offset = cursor_offset + #lines[index] + 1
    end

    cursor_offset = cursor_offset + col + 1 -- Lua string positions are one-based.
    local text = table.concat(lines, "\n")
    local search_from = 1

    while true do
        local command_start, command_end, key, page_arg = text:find(
            "\\citepage%s*{%s*([^{}]+)%s*}%s*{%s*([^{}]+)%s*}",
            search_from
        )

        if not command_start then
            break
        end

        if cursor_offset >= command_start and cursor_offset <= command_end + 1 then
            key = vim.trim(key or "")
            page_arg = vim.trim(page_arg or "")
            local first_page = page_arg:match("^(%d+)")

            if key == "" then
                return nil, "The \\citepage command under the cursor has no citation key."
            end

            if not first_page then
                return nil,
                    "Open Cited Page currently requires a numeric page or range such as 42 or 42--45."
            end

            return {
                citation_key = key,
                page = tonumber(first_page),
                page_argument = page_arg,
            }
        end

        search_from = command_end + 1
    end

    return nil, "Place the cursor on a \\citepage{key}{page} command first."
end

function M.open_cited_page()
    local citation, parse_err = citepage_under_cursor()

    if not citation then
        notify_error(parse_err)
        return
    end

    client.open_cited_page(citation.citation_key, citation.page, function(err, result)
        if err then
            notify_error(err)
            return
        end

        if result and result.opened == "zotero" and result.reason then
            vim.notify("References: " .. tostring(result.reason), vim.log.levels.WARN)
        end
    end)
end

local function register_which_key()
    local ok, wk = pcall(require, "which-key")

    if not ok then
        return false
    end

    if type(wk.add) == "function" then
        wk.add({
            { "<leader>r", group = "references" },
        })
    elseif type(wk.register) == "function" then
        wk.register({
            r = { name = "+references" },
        }, { prefix = "<leader>" })
    end

    return true
end

function M.setup()
    if setup_done then
        return M
    end

    setup_done = true

    vim.api.nvim_create_user_command("References", M.search_course, {
        desc = "Search references in the current course Zotero collection",
    })
    vim.api.nvim_create_user_command("ReferencesAll", M.search_all, {
        desc = "Search the complete Zotero library",
    })
    vim.api.nvim_create_user_command("ReferencesOpen", M.open_reference, {
        desc = "Open a course reference in Skim/Zotero",
    })
    vim.api.nvim_create_user_command("ReferencesOpenPage", M.open_cited_page, {
        desc = "Open the \\citepage target under the cursor in Skim",
    })

    vim.keymap.set("n", "<leader>rr", M.search_course, {
        desc = "Search References",
    })
    vim.keymap.set("n", "<leader>rR", M.search_all, {
        desc = "Search All References",
    })
    vim.keymap.set("n", "<leader>ro", M.open_reference, {
        desc = "Open Reference",
    })
    vim.keymap.set("n", "<leader>rp", M.open_cited_page, {
        desc = "Open Cited Page",
    })

    if not register_which_key() then
        vim.api.nvim_create_autocmd("User", {
            pattern = "VeryLazy",
            once = true,
            callback = register_which_key,
        })
    end

    return M
end

return M
