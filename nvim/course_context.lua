local M = {}

-- Reference commands/keymaps are independent of whether this Neovim instance
-- has a usable terminal/TTY for the Hammerspoon focus bridge. Register them
-- before any bridge-specific early return so :References and <leader>r* are
-- available in every normal Neovim session.
local function setupReferences()
    local ok, references = pcall(require, "course-references")

    if not ok then
        vim.schedule(function()
            vim.notify(
                "Course references failed to load: " .. tostring(references),
                vim.log.levels.ERROR
            )
        end)
        return
    end

    if type(references.setup) == "function" then
        references.setup()
    end
end

setupReferences()

local stateDir = vim.fn.expand(
    "~/.local/state/course-workflow/nvim"
)

vim.fn.mkdir(stateDir, "p")

local pid = vim.fn.getpid()

local tty = vim.trim(
    vim.fn.system({
        "/bin/ps",
        "-p",
        tostring(pid),
        "-o",
        "tty=",
    })
)

tty = tty:gsub("^/dev/", "")

-- If Neovim somehow has no terminal, simply disable this bridge.
if tty == "" or tty == "??" then
    return M
end

local statePath = stateDir .. "/" .. tty .. ".json"
local lastActivity = 0

local function removeState()
    pcall(os.remove, statePath)
end

local function atomicWrite(contents)
    local temporaryPath = string.format(
        "%s.%d.tmp",
        statePath,
        pid
    )

    local file = io.open(temporaryPath, "wb")

    if not file then
        return
    end

    file:write(contents)
    file:write("\n")
    file:close()

    local ok = os.rename(temporaryPath, statePath)

    if not ok then
        pcall(os.remove, temporaryPath)
    end
end

local function publish()
    local buffer = vim.api.nvim_get_current_buf()

    if not vim.api.nvim_buf_is_valid(buffer) then
        removeState()
        return
    end

    -- Ignore Telescope prompts, help buffers, terminals, etc.
    if vim.bo[buffer].buftype ~= "" then
        removeState()
        return
    end

    local path = vim.api.nvim_buf_get_name(buffer)

    if path == "" then
        removeState()
        return
    end

    path = vim.fn.fnamemodify(path, ":p")

    local payload = {
        path = path,
        pid = pid,
        tty = tty,
        updated = os.time(),
        -- Milliseconds since boot are comparable between Neovim processes.
        last_active_ms = lastActivity,
        server = vim.v.servername,
        executable = vim.fn.exepath("nvim"),
        cursor = vim.api.nvim_win_get_cursor(0),
        changedtick = vim.api.nvim_buf_get_changedtick(buffer),
    }

    local ok, encoded = pcall(
        vim.json.encode,
        payload
    )

    if not ok then
        return
    end

    atomicWrite(encoded)
end

local function publishActivity()
    lastActivity = math.floor((vim.uv or vim.loop).hrtime() / 1000000)
    publish()
end

-- Called through nvim --server ... --remote-expr. The target buffer and cursor
-- must still be the ones captured before Shortcuts started its model request.
-- Return a single line so Hammerspoon can distinguish success from failure.
function M.insert_from_file(manifestPath)
    local file = io.open(manifestPath, "rb")
    if not file then return "ERROR: Missing insertion manifest" end
    local contents = file:read("*a")
    file:close()
    local parsed, request = pcall(vim.json.decode, contents)
    if not parsed or type(request) ~= "table" then
        return "ERROR: Invalid insertion manifest"
    end

    if type(request.path) ~= "string" or type(request.cursor) ~= "table"
        or type(request.cursor[1]) ~= "number"
        or type(request.cursor[2]) ~= "number"
        or type(request.changedtick) ~= "number" then
        return "ERROR: Incomplete insertion manifest"
    end

    local buffer = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    if vim.bo[buffer].buftype ~= "" or vim.bo[buffer].readonly
        or not vim.bo[buffer].modifiable
        or vim.api.nvim_buf_get_name(buffer) ~= request.path
        or vim.api.nvim_buf_get_changedtick(buffer) ~= request.changedtick
        or cursor[1] ~= request.cursor[1]
        or cursor[2] ~= request.cursor[2] then
        return "ERROR: Neovim buffer or cursor changed; capture again"
    end
    if type(request.text) ~= "string" or request.text == "" then
        return "ERROR: Empty problem"
    end

    local line = vim.api.nvim_buf_get_lines(buffer, cursor[1] - 1, cursor[1], false)[1]
    local prefix = line:sub(1, cursor[2])
    local text = (prefix ~= "" and "\n" or "") .. request.text .. "\n"
    local lines = vim.split(text, "\n", { plain = true })
    vim.api.nvim_buf_set_text(
        buffer, cursor[1] - 1, cursor[2], cursor[1] - 1, cursor[2], lines
    )
    local ok, err = pcall(vim.cmd, "write")
    if not ok then return "ERROR: Inserted but could not save: " .. tostring(err) end
    publishActivity()
    return "OK"
end

local group = vim.api.nvim_create_augroup(
    "CourseWorkflowContext",
    { clear = true }
)

vim.api.nvim_create_autocmd({
    "BufEnter",
    "BufWinEnter",
    "BufFilePost",
    "FocusGained",
    "CursorMoved",
    "CursorMovedI",
}, {
    group = group,
    callback = publishActivity,
})

vim.api.nvim_create_autocmd("FocusLost", {
    group = group,
    callback = publish,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = removeState,
})

vim.schedule(publishActivity)

return M
