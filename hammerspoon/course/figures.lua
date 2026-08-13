local Figures = {}

local Context = require("course.context")
local Util = require("course.util")

Figures.MODE = {
    NEW = "new",
    FIND = "find",
}

local VALID_MODES = {
    new = true,
    find = true,
}

-- The course layer owns only scope. The actual SVG creation/open/export/watch
-- behavior stays in the existing noah-inkscape workflow.
function Figures.scope(course, workContext)
    if type(course) ~= "table" or not Util.isNonEmptyString(course.id) then
        return nil, "Figure scope requires a valid course object."
    end

    if workContext == Context.WORK_CONTEXT.NOTES then
        return {
            workContext = workContext,
            projectRoot = course.notes.root,
            figuresDir = course.notes.figures,
        }
    end

    if workContext == Context.WORK_CONTEXT.ASSIGNMENT then
        return {
            workContext = workContext,
            projectRoot = course.assignments.root,
            figuresDir = course.assignments.figures,
        }
    end

    return nil, "Figure scope requires notes or assignment context."
end

local REPO_ROOT_LUA = [[
local function workflow_repo_root()
  local module_path = package.searchpath("noah-inkscape", package.path)
  if not module_path then
    vim.notify("noah-inkscape is not installed in Neovim", vim.log.levels.ERROR)
    return nil
  end
  module_path = (vim.uv and vim.uv.fs_realpath(module_path))
    or (vim.loop and vim.loop.fs_realpath(module_path))
    or module_path
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(module_path))))
end
]]

local NEW_LUA = REPO_ROOT_LUA .. [[
local figures_dir = vim.env.NOAH_COURSE_FIGURES_DIR
local repo_root = workflow_repo_root()
if not repo_root then return end
local telescope = require("noah-inkscape.telescope")
local new_script = vim.fs.joinpath(repo_root, "scripts", "new_figure")
local templates_dir = vim.fs.joinpath(repo_root, "templates")

vim.ui.input({ prompt = "Figure name: " }, function(name)
  if not name or vim.trim(name) == "" then return end
  name = vim.trim(name)

  telescope.pick_template({
    templates_dir = templates_dir,
    on_select = function(template_path)
      vim.system(
        { new_script, name, figures_dir, template_path },
        { text = true },
        function(result)
          vim.schedule(function()
            if result.code == 0 then
              vim.notify("Created figure: " .. name, vim.log.levels.INFO)
            else
              local message = result.stderr
              if not message or message == "" then message = result.stdout end
              if not message or message == "" then message = "Unknown error" end
              vim.notify("Figure creation failed:\n" .. message, vim.log.levels.ERROR)
            end
          end)
        end
      )
    end,
  })
end)
]]

local FIND_LUA = REPO_ROOT_LUA .. [[
local figures_dir = vim.env.NOAH_COURSE_FIGURES_DIR
local repo_root = workflow_repo_root()
if not repo_root then return end
local telescope = require("noah-inkscape.telescope")
local open_script = vim.fs.joinpath(repo_root, "scripts", "open_figure")
local new_script = vim.fs.joinpath(repo_root, "scripts", "new_figure")
local templates_dir = vim.fs.joinpath(repo_root, "templates")

local function exists(path)
  return vim.fn.filereadable(path) == 1
end

local function notify_missing(path)
  vim.notify("Figure artifact does not exist:\n" .. path, vim.log.levels.WARN)
end

local function relative_name(path)
  local prefix = figures_dir
  if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
  local relative = path
  if path:sub(1, #prefix) == prefix then
    relative = path:sub(#prefix + 1)
  else
    relative = vim.fs.basename(path)
  end
  return relative:gsub("%.svg$", "")
end

local function create_figure(name)
  local function choose_template(final_name)
    telescope.pick_template({
      templates_dir = templates_dir,
      on_select = function(template_path)
        vim.system(
          { new_script, final_name, figures_dir, template_path },
          { text = true },
          function(result)
            vim.schedule(function()
              if result.code == 0 then
                vim.notify("Created figure: " .. final_name, vim.log.levels.INFO)
              else
                local message = result.stderr
                if not message or message == "" then message = result.stdout end
                if not message or message == "" then message = "Unknown error" end
                vim.notify("Figure creation failed:\n" .. message, vim.log.levels.ERROR)
              end
            end)
          end
        )
      end,
    })
  end

  if name and vim.trim(name) ~= "" then
    choose_template(vim.trim(name))
    return
  end

  vim.ui.input({ prompt = "Figure name: " }, function(input)
    if not input or vim.trim(input) == "" then return end
    choose_template(vim.trim(input))
  end)
end

local function choose_action(svg_path)
  local base = svg_path:gsub("%.svg$", "")
  local pdf_path = base .. ".pdf"
  local tex_path = base .. ".pdf_tex"
  local actions = {
    { label = "Open in Inkscape", kind = "open-svg" },
    { label = "Open exported PDF", kind = "open-pdf" },
    { label = "Reveal source SVG", kind = "reveal-svg" },
    { label = "Reveal exported PDF", kind = "reveal-pdf" },
    { label = "Reveal pdf_tex", kind = "reveal-tex" },
    { label = "Copy LaTeX", kind = "copy-latex" },
  }

  vim.ui.select(actions, {
    prompt = "Figure action",
    format_item = function(item) return item.label end,
  }, function(item)
    if not item then return end

    if item.kind == "open-svg" then
      vim.system({ open_script, svg_path }, { text = true })
      return
    end

    if item.kind == "open-pdf" then
      if not exists(pdf_path) then notify_missing(pdf_path); return end
      vim.system({ "/usr/bin/open", pdf_path }, { text = true })
      return
    end

    if item.kind == "reveal-svg" then
      vim.system({ "/usr/bin/open", "-R", svg_path }, { text = true })
      return
    end

    if item.kind == "reveal-pdf" then
      if not exists(pdf_path) then notify_missing(pdf_path); return end
      vim.system({ "/usr/bin/open", "-R", pdf_path }, { text = true })
      return
    end

    if item.kind == "reveal-tex" then
      if not exists(tex_path) then notify_missing(tex_path); return end
      vim.system({ "/usr/bin/open", "-R", tex_path }, { text = true })
      return
    end

    if item.kind == "copy-latex" then
      local code = "\\incfig{" .. relative_name(svg_path) .. "}"
      vim.fn.setreg("+", code)
      vim.notify("Copied: " .. code, vim.log.levels.INFO)
    end
  end)
end

telescope.pick({
  figures_dir = figures_dir,
  on_open = choose_action,
  on_new = create_figure,
})
]]

function Figures.luaForMode(mode)
    if not VALID_MODES[mode] then
        return nil, 'Unknown figure workflow mode "' .. tostring(mode) .. '".'
    end

    if mode == Figures.MODE.NEW then
        return NEW_LUA
    end

    return FIND_LUA
end

function Figures.invocation(course, workContext, mode)
    local scope, scopeErr = Figures.scope(course, workContext)

    if not scope then
        return nil, scopeErr
    end

    local lua, luaErr = Figures.luaForMode(mode)

    if not lua then
        return nil, luaErr
    end

    local temporaryRoot = os.getenv("TMPDIR") or "/tmp"
    local bridgePath = Util.joinPath(
        temporaryRoot,
        "noah-course-figure-" .. mode .. ".lua"
    )

    -- The interactive bridge is written to a tiny disposable Lua file before
    -- launching Neovim. Keeping the multiline Lua out of `nvim -c` avoids
    -- Ex-command parsing/quoting problems. Paths themselves still travel only
    -- through environment variables.
    local command = table.concat({
        "env",
        "NOAH_COURSE_FIGURES_DIR=" .. Util.shellQuote(scope.figuresDir),
        "NOAH_COURSE_FIGURE_MODE=" .. Util.shellQuote(mode),
        "NOAH_COURSE_FIGURE_BRIDGE=" .. Util.shellQuote(bridgePath),
        "nvim",
        "-c",
        Util.shellQuote("lua dofile(vim.env.NOAH_COURSE_FIGURE_BRIDGE)"),
    }, " ")

    return {
        mode = mode,
        workContext = workContext,
        projectRoot = scope.projectRoot,
        figuresDir = scope.figuresDir,
        bridgePath = bridgePath,
        bridgeContents = lua,
        command = command,
    }
end

return Figures
