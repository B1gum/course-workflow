local M = {}

M.endpoint = "http://127.0.0.1:23120/v1/reference"

local function trim(value)
    value = value or ""
    return value:gsub("%s+$", "")
end

local function error_message(result)
    local stderr = trim(result.stderr)
    local stdout = trim(result.stdout)

    if stdout ~= "" then
        local ok, decoded = pcall(vim.json.decode, stdout)
        if ok and type(decoded) == "table" and type(decoded.error) == "string" then
            return decoded.error
        end
    end

    if stderr ~= "" then
        return stderr
    end

    if result.code ~= 0 then
        return "reference service request failed with exit code " .. tostring(result.code)
    end

    return "reference service returned an invalid response"
end

function M.request(payload, callback)
    local ok, encoded = pcall(vim.json.encode, payload)

    if not ok then
        callback("could not encode reference request")
        return
    end

    vim.system({
        "/usr/bin/curl",
        "--silent",
        "--show-error",
        "--connect-timeout", "2",
        "--max-time", "30",
        "--request", "POST",
        "--header", "Content-Type: application/json",
        "--data-binary", encoded,
        M.endpoint,
    }, { text = true }, function(result)
        vim.schedule(function()
            local stdout = trim(result.stdout)
            local decoded_ok, decoded = pcall(vim.json.decode, stdout)

            if result.code ~= 0 or not decoded_ok or type(decoded) ~= "table" then
                callback(
                    error_message(result)
                        .. ". Reload/start Hammerspoon if the course reference service is not running."
                )
                return
            end

            if decoded.ok ~= true then
                callback(decoded.error or "reference operation failed")
                return
            end

            callback(nil, decoded.result)
        end)
    end)
end

function M.search_course(options, callback)
    options = options or {}
    M.request({
        command = "search",
        course = options.course,
        path = options.path,
    }, callback)
end

function M.search_all(callback)
    M.request({
        command = "search",
        all = true,
    }, callback)
end

function M.open_reference(item_key, callback)
    M.request({
        command = "open-reference",
        itemKey = item_key,
    }, callback)
end

function M.open_zotero_item(item_key, callback)
    M.request({
        command = "open-zotero-item",
        itemKey = item_key,
    }, callback)
end

function M.open_cited_page(citation_key, page, callback)
    M.request({
        command = "open-cited-page",
        citationKey = citation_key,
        page = page,
    }, callback)
end

return M
