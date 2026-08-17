local Util = {}

local HOME = os.getenv("HOME") or ""

function Util.trim(value)
    if type(value) ~= "string" then
        return value
    end

    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.isNonEmptyString(value)
    return type(value) == "string" and Util.trim(value) ~= ""
end

function Util.shellQuote(value)
    value = tostring(value)
    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

function Util.joinPath(...)
    local parts = { ... }
    local result = ""

    for index, part in ipairs(parts) do
        if type(part) ~= "string" or part == "" then
            error("joinPath received an empty/non-string component at index " .. tostring(index))
        end

        if result == "" then
            result = part:gsub("/+$", "")
        else
            result = result .. "/" .. part:gsub("^/+", ""):gsub("/+$", "")
        end
    end

    if result == "" then
        return "/"
    end

    return result
end

function Util.normalizePath(path)
    if not Util.isNonEmptyString(path) then
        return nil
    end

    path = Util.trim(path)

    if path == "~" then
        path = HOME
    elseif path:sub(1, 2) == "~/" then
        path = HOME .. path:sub(2)
    end

    local ok, absolute = pcall(hs.fs.pathToAbsolute, path)

    if ok and Util.isNonEmptyString(absolute) then
        path = absolute
    end

    if path ~= "/" then
        path = path:gsub("/+$", "")
    end

    return path
end

function Util.isPathWithin(path, root)
    path = Util.normalizePath(path)
    root = Util.normalizePath(root)

    if not path or not root then
        return false
    end

    if path == root then
        return true
    end

    return path:sub(1, #root + 1) == root .. "/"
end

function Util.readFile(path)
    local file, err = io.open(path, "rb")

    if not file then
        return nil, err
    end

    local contents = file:read("*a")
    file:close()

    return contents
end

function Util.writeFileAtomic(path, contents)
    if not Util.isNonEmptyString(path) then
        return nil, "Atomic write requires a non-empty path."
    end

    if type(contents) ~= "string" then
        return nil, "Atomic write contents must be a string."
    end

    path = Util.trim(path)

    local parent = path:match("^(.*)/[^/]+$") or "."

    if parent == "" then
        parent = "/"
    end

    if hs.fs.attributes(parent, "mode") ~= "directory" then
        return nil, "Atomic write parent directory does not exist: " .. parent
    end

    if hs.fs.attributes(path, "mode") == "directory" then
        return nil, "Atomic write destination is a directory: " .. path
    end

    local temporaryPath = string.format(
        "%s.tmp.%d.%06d",
        path,
        os.time(),
        math.random(0, 999999)
    )

    local file, openErr = io.open(temporaryPath, "wb")

    if not file then
        return nil, openErr
    end

    local ok, writeErr = file:write(contents)

    if not ok then
        file:close()
        pcall(os.remove, temporaryPath)
        return nil, writeErr
    end

    local closeOk, closeErr = file:close()

    if closeOk == nil then
        pcall(os.remove, temporaryPath)
        return nil, closeErr
    end

    local renamed, renameErr = os.rename(temporaryPath, path)

    if not renamed then
        pcall(os.remove, temporaryPath)
        return nil, renameErr
    end

    return true
end

function Util.readJson(path)
    local mode = hs.fs.attributes(path, "mode")

    if mode ~= "file" then
        return nil, "JSON file does not exist or is not a regular file: " .. path
    end

    local contents, readErr = Util.readFile(path)

    if not contents then
        return nil, "Could not read JSON file " .. path .. ": " .. tostring(readErr)
    end

    local ok, value = pcall(hs.json.decode, contents)

    if not ok or type(value) ~= "table" then
        return nil, "Invalid JSON in " .. path .. "."
    end

    return value
end

function Util.copyArray(values)
    local result = {}

    for index, value in ipairs(values or {}) do
        result[index] = value
    end

    return result
end

return Util
