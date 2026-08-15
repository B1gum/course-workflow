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

local group = vim.api.nvim_create_augroup(
    "CourseWorkflowContext",
    { clear = true }
)

vim.api.nvim_create_autocmd({
    "BufEnter",
    "BufWinEnter",
    "BufFilePost",
    "FocusGained",
}, {
    group = group,
    callback = publish,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = removeState,
})

vim.schedule(publish)

return M
