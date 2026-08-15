local ReferenceServer = {}

local Actions = require("course.actions")

ReferenceServer.PORT = 23120
ReferenceServer.PATH = "/v1/reference"
ReferenceServer._server = nil

local JSON_HEADERS = {
    ["Content-Type"] = "application/json; charset=utf-8",
    ["Cache-Control"] = "no-store",
}

local function response(value, status)
    return hs.json.encode(value), status or 200, JSON_HEADERS
end

local function cleanOptions(request)
    local options = { returnOnly = true }

    if type(request) ~= "table" then
        return options
    end

    if type(request.course) == "string" and request.course ~= "" then
        options.course = request.course
    end

    if type(request.path) == "string" and request.path ~= "" then
        options.path = request.path
    end

    return options
end

function ReferenceServer.dispatch(request, runtime)
    if type(request) ~= "table" then
        return nil, "Reference service request must be a JSON object."
    end

    local command = request.command

    if command == "search" then
        if request.all == true then
            return Actions.searchAllReferences({ returnOnly = true }, runtime)
        end

        return Actions.searchReferences(cleanOptions(request), runtime)
    end

    if command == "open-reference" then
        return Actions.openReference({
            itemKey = request.itemKey,
            citationKey = request.citationKey,
        }, runtime)
    end

    if command == "open-zotero-item" then
        return Actions.openZoteroItem({ itemKey = request.itemKey }, runtime)
    end

    if command == "open-cited-page" then
        return Actions.openCitedPage({
            citationKey = request.citationKey,
            page = request.page,
        }, runtime)
    end

    if command == "open-collection" then
        return Actions.openReferences(cleanOptions(request), runtime)
    end

    return nil, 'Unknown reference service command "' .. tostring(command) .. '".'
end

local function callback(method, path, _, body)
    if method ~= "POST" or path ~= ReferenceServer.PATH then
        return response({
            ok = false,
            error = "Not found.",
        }, 404)
    end

    local ok, request = pcall(hs.json.decode, body or "")

    if not ok or type(request) ~= "table" then
        return response({
            ok = false,
            error = "Request body must contain valid JSON.",
        }, 400)
    end

    local dispatchOk, result, err = xpcall(function()
        local value, dispatchErr = ReferenceServer.dispatch(request)
        return value, dispatchErr
    end, debug.traceback)

    if not dispatchOk then
        return response({
            ok = false,
            error = tostring(result),
        }, 500)
    end

    if not result then
        return response({
            ok = false,
            error = tostring(err or "Reference operation failed."),
        }, 400)
    end

    return response({
        ok = true,
        result = result,
    }, 200)
end

function ReferenceServer.start()
    ReferenceServer.stop()

    local server = hs.httpserver.new(false, false)
    server:setInterface("127.0.0.1")
    server:setPort(ReferenceServer.PORT)
    server:maxBodySize(64 * 1024)
    server:setCallback(callback)
    server:start()

    ReferenceServer._server = server
    return true
end

function ReferenceServer.stop()
    if ReferenceServer._server then
        ReferenceServer._server:stop()
    end

    ReferenceServer._server = nil
    return true
end

return ReferenceServer
