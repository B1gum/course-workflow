local Capture = {}

local References = require("course.references")
local Util = require("course.util")

Capture.POLL_INTERVAL = 0.5
Capture.SETTLE_SECONDS = 2.5
Capture.TIMEOUT_SECONDS = 90
Capture._session = nil

local function runtimeFunction(runtime, name, fallback)
    if type(runtime) == "table" and type(runtime[name]) == "function" then
        return runtime[name]
    end

    return fallback
end

local function defaultNotify(message)
    hs.alert.show(message)
    return true
end

local function nowSeconds()
    return hs.timer.absoluteTime() / 1000000000
end

local function startEvery(interval, callback)
    return hs.timer.doEvery(interval, callback)
end

local function frontmostBundleID()
    local app = hs.application.frontmostApplication()
    return app and app:bundleID() or nil
end

local function lowerAttribute(element, attribute)
    local ok, value = pcall(function()
        return element:attributeValue(attribute)
    end)

    if not ok or type(value) ~= "string" then
        return ""
    end

    return value:lower()
end

local function supportsPress(element)
    local ok, names = pcall(function()
        return element:actionNames()
    end)

    if not ok or type(names) ~= "table" then
        return false
    end

    for _, name in ipairs(names) do
        if name == "AXPress" then
            return true
        end
    end

    return false
end

local function hasToolbarAncestor(element)
    local ok, path = pcall(function()
        return element:path()
    end)

    if not ok or type(path) ~= "table" then
        return false
    end

    for _, ancestor in ipairs(path) do
        local roleOK, role = pcall(function()
            return ancestor:attributeValue("AXRole")
        end)

        if roleOK and role == "AXToolbar" then
            return true
        end
    end

    return false
end

local function zoteroButtonScore(element)
    local role = lowerAttribute(element, "AXRole")

    if role ~= "axbutton" or not hasToolbarAncestor(element) or not supportsPress(element) then
        return nil
    end

    local title = lowerAttribute(element, "AXTitle")
    local description = lowerAttribute(element, "AXDescription")
    local help = lowerAttribute(element, "AXHelp")
    local identifier = lowerAttribute(element, "AXIdentifier")
    local combined = table.concat({ title, description, help, identifier }, " ")

    if not combined:find("zotero", 1, true) then
        return nil
    end

    local score = 1

    if combined:find("save to zotero", 1, true) then
        score = score + 10
    end

    if combined:find("zotero connector", 1, true) then
        score = score + 5
    end

    return score
end

local function defaultPressSafariConnector(bundleId, callback)
    local app = hs.application.get(bundleId)

    if not app then
        callback(nil, "Safari is not running.")
        return false
    end

    if frontmostBundleID() ~= bundleId then
        callback(nil, "Safari must be the frontmost application so the current page can be captured.")
        return false
    end

    local root = hs.axuielement.applicationElement(app)

    if not root then
        callback(nil, "Could not access Safari's accessibility hierarchy.")
        return false
    end

    root:elementSearch(function(message, results)
        if type(message) == "string" and message:sub(1, 2) == "**" then
            callback(nil, "Safari accessibility search failed: " .. message)
            return
        end

        local best
        local bestScore = -1
        local tied = false

        for _, element in ipairs(results or {}) do
            local score = zoteroButtonScore(element)

            if score and score > bestScore then
                best = element
                bestScore = score
                tied = false
            elseif score and score == bestScore then
                tied = true
            end
        end

        if not best then
            callback(nil,
                "Could not find the Zotero Connector button in Safari's toolbar. "
                    .. "Enable the Zotero Safari extension, keep its button in the toolbar, "
                    .. "and allow Hammerspoon Accessibility access."
            )
            return
        end

        if tied and bestScore <= 1 then
            callback(nil, "More than one ambiguous Zotero toolbar button was found; refusing to guess.")
            return
        end

        local pressed, pressErr = best:performAction("AXPress")

        if not pressed then
            callback(nil, "Safari exposed the Zotero button, but AXPress failed: " .. tostring(pressErr))
            return
        end

        callback(true)
    end, function(element)
        return zoteroButtonScore(element) ~= nil
    end, {
        depth = 12,
        count = 8,
    })

    return true
end

local function stopTimer(session)
    if session and session.timer then
        pcall(function()
            session.timer:stop()
        end)
        session.timer = nil
    end
end

local function finish(session, ok, message, result)
    if Capture._session ~= session then
        return
    end

    stopTimer(session)
    Capture._session = nil

    local notify = session.notify or defaultNotify

    if message and message ~= "" then
        notify(message)
    end

    if type(session.onComplete) == "function" then
        pcall(session.onComplete, ok, result or message)
    end
end

local function itemKey(entry)
    if type(entry) ~= "table" then
        return nil
    end

    local data = type(entry.data) == "table" and entry.data or entry
    local key = entry.key or data.key

    if not Util.isNonEmptyString(key) then
        return nil
    end

    return Util.trim(key)
end

local function isCaptureCandidate(entry)
    local data = type(entry) == "table" and (entry.data or entry) or {}
    local itemType = data.itemType

    -- Notes/annotations are never the bibliographic result of a normal
    -- Connector capture. Standalone PDF attachments remain eligible so a
    -- direct-PDF save can still be filed by the workflow.
    return itemType ~= "note" and itemType ~= "annotation"
end

local function newCaptureKeys(session)
    local entries, err = References.newTopLevelItemsSince(
        session.baseline,
        References.CAPTURE_RECENT_LIMIT,
        session.runtime
    )

    if not entries then
        return nil, err
    end

    local keys = {}

    for _, entry in ipairs(entries) do
        if isCaptureCandidate(entry) then
            local key = itemKey(entry)
            if key then
                table.insert(keys, key)
            end
        end
    end

    return keys
end

local function signature(keys)
    local copy = {}
    for _, key in ipairs(keys or {}) do
        table.insert(copy, key)
    end
    table.sort(copy)
    return table.concat(copy, "\0")
end

local function finalizeCapturedItems(session, keys)
    local assigned, err = References.assignCapturedItems(keys, {
        unfiled = session.unfiled,
        collectionKey = session.collectionKey,
    }, session.runtime)

    if not assigned then
        finish(session, false, "Reference captured, but course assignment failed: " .. tostring(err))
        return
    end

    local count = tonumber(assigned.count) or #keys
    local noun = count == 1 and "reference" or "references"
    local destination = session.unfiled
        and "Unfiled"
        or tostring(session.courseName or session.collectionKey)

    finish(
        session,
        true,
        string.format("Saved %d %s → %s", count, noun, destination),
        assigned
    )
end

local function poll(session)
    if Capture._session ~= session then
        return
    end

    local now = session.now()

    if now - session.startedAt >= session.timeout then
        finish(session, false, "Reference capture timed out; Zotero did not create a new item.")
        return
    end

    local keys, err = newCaptureKeys(session)

    if not keys then
        finish(session, false, "Reference capture could not inspect Zotero: " .. tostring(err))
        return
    end

    if #keys == 0 then
        return
    end

    local currentSignature = signature(keys)

    if currentSignature ~= session.lastSignature then
        session.lastSignature = currentSignature
        session.lastChangeAt = now
        session.pendingKeys = keys
        return
    end

    if now - session.lastChangeAt >= session.settle then
        finalizeCapturedItems(session, session.pendingKeys or keys)
    end
end

local function versionAtLeast(version, wantedMajor, wantedMinor)
    if not Util.isNonEmptyString(version) then
        return false
    end

    local major, minor = Util.trim(version):match("^(%d+)%.(%d+)")
    major = tonumber(major)
    minor = tonumber(minor)

    if not major or not minor then
        return false
    end

    return major > wantedMajor or (major == wantedMajor and minor >= wantedMinor)
end

function Capture.start(options, runtime)
    options = options or {}

    if Capture._session then
        return nil, "A Zotero capture is already in progress."
    end

    if not Util.isNonEmptyString(options.zoteroBundleId)
        or not Util.isNonEmptyString(options.safariBundleId) then

        return nil, "Reference capture requires zoteroBundleId and safariBundleId."
    end

    local unfiled = options.unfiled == true
    local collectionKey = options.collectionKey

    if not unfiled and not Util.isNonEmptyString(collectionKey) then
        return nil, "Course-aware capture requires a stable Zotero collectionKey."
    end

    local ready, readyErr = References.ensureReady({
        zoteroBundleId = options.zoteroBundleId,
    }, runtime)

    if not ready then
        return nil, readyErr
    end

    local helper, helperErr = References.helperReady(runtime)

    if not helper then
        return nil, helperErr
    end

    if not versionAtLeast(helper.version, 1, 1) then
        return nil,
            "Course-aware browser capture requires Course Workflow Zotero Helper 1.1 or newer. "
                .. "Install the XPI bundled with the current workflow."
    end

    local baseline, baselineErr = References.topLevelItemKeys(runtime)

    if not baseline then
        return nil, baselineErr
    end

    local getFrontmost = runtimeFunction(runtime, "frontmostBundleID", frontmostBundleID)
    local safariBundleId = Util.trim(options.safariBundleId)

    if getFrontmost() ~= safariBundleId then
        return nil, "Save Reference must be invoked while Safari is frontmost."
    end

    local session = {
        baseline = baseline,
        unfiled = unfiled,
        collectionKey = Util.isNonEmptyString(collectionKey) and Util.trim(collectionKey) or nil,
        courseName = options.courseName,
        runtime = runtime,
        startedAt = runtimeFunction(runtime, "now", nowSeconds)(),
        now = runtimeFunction(runtime, "now", nowSeconds),
        settle = tonumber(options.settleSeconds) or Capture.SETTLE_SECONDS,
        timeout = tonumber(options.timeoutSeconds) or Capture.TIMEOUT_SECONDS,
        notify = runtimeFunction(runtime, "notify", defaultNotify),
        onComplete = options.onComplete,
        lastSignature = nil,
        lastChangeAt = nil,
        pendingKeys = nil,
    }

    Capture._session = session

    local press = runtimeFunction(runtime, "pressSafariConnector", defaultPressSafariConnector)
    local started = press(safariBundleId, function(ok, err)
        if Capture._session ~= session then
            return
        end

        if not ok then
            finish(session, false, "Could not start Zotero Connector capture: " .. tostring(err))
            return
        end

        local timerFactory = runtimeFunction(runtime, "timerEvery", startEvery)
        session.timer = timerFactory(Capture.POLL_INTERVAL, function()
            poll(session)
        end)

        -- Poll once immediately; very fast saves may already have completed.
        poll(session)
    end)

    if started == false and Capture._session == session then
        finish(session, false, "Could not start Zotero Connector capture.")
        return nil, "Could not start Zotero Connector capture."
    end

    return {
        started = true,
        unfiled = unfiled,
        collectionKey = session.collectionKey,
        courseName = session.courseName,
    }
end

function Capture.cancel(message)
    local session = Capture._session

    if not session then
        return false
    end

    finish(session, false, message or "Reference capture cancelled.")
    return true
end

return Capture
