local Tests = {}

local Capture = require("course.reference_capture")

local function fail(message)
    error(message, 2)
end

local function assertEqual(actual, expected, label)
    if actual ~= expected then
        fail(string.format(
            "%s: expected %s, got %s",
            label,
            tostring(expected),
            tostring(actual)
        ))
    end
end

local function assertNil(value, label)
    if value ~= nil then
        fail(string.format("%s: expected nil, got %s", label, tostring(value)))
    end
end

local function assertTruthy(value, label)
    if not value then
        fail(label .. ": expected a truthy value")
    end
end

local function rpc(result)
    return 200, hs.json.encode({
        jsonrpc = "2.0",
        id = 1,
        result = result,
    }), {}
end

local function makeRuntime()
    local clock = 0
    local connectorPressed = false
    local tick = nil
    local completion = nil
    local helperPayload = nil

    local oldItem = {
        key = "OLD1",
        data = {
            key = "OLD1",
            itemType = "journalArticle",
            dateAdded = "2026-08-15T10:00:00Z",
        },
    }
    local newItem = {
        key = "NEW1",
        data = {
            key = "NEW1",
            itemType = "journalArticle",
            dateAdded = "2026-08-15T10:01:00Z",
        },
    }

    local runtime = {
        launchBundle = function()
            fail("Zotero should already be ready in capture tests")
        end,
        sleep = function() end,
        now = function()
            return clock
        end,
        frontmostBundleID = function()
            return "com.apple.Safari"
        end,
        pressSafariConnector = function(_, callback)
            connectorPressed = true
            callback(true)
            return true
        end,
        timerEvery = function(_, callback)
            tick = callback
            return {
                stop = function() end,
            }
        end,
        notify = function() end,
        httpGet = function(url)
            if url:find("/course-workflow/ready", 1, true) then
                return 200, hs.json.encode({
                    ready = true,
                    version = "1.1.0",
                    zotero = "9.0-test",
                }), {}
            end

            if url:find("/items/top", 1, true) then
                return 200, hs.json.encode(
                    connectorPressed and { newItem, oldItem } or { oldItem }
                ), {}
            end

            return 404, "not found", {}
        end,
        httpPost = function(url, body)
            local payload = hs.json.decode(body)

            if url:find("/better-bibtex/json-rpc", 1, true) then
                if payload.method == "api.ready" then
                    return rpc({
                        betterbibtex = "7.0-test",
                        zotero = "9.0-test",
                    })
                end
                return 500, "unexpected RPC", {}
            end

            if url:find("/course-workflow/assign-capture", 1, true) then
                helperPayload = payload
                return 200, hs.json.encode({
                    count = #payload.itemKeys,
                    itemKeys = payload.itemKeys,
                    changed = payload.itemKeys,
                    unfiled = payload.unfiled == true,
                    collectionKey = payload.collectionKey,
                }), {}
            end

            return 404, "not found", {}
        end,
    }

    return runtime, {
        advanceAndTick = function(seconds)
            clock = clock + seconds
            assertTruthy(tick, "capture polling timer")
            tick()
        end,
        setCompletion = function(value)
            completion = value
        end,
        helperPayload = function()
            return helperPayload
        end,
        completion = function()
            return completion
        end,
    }
end

function Tests.run()
    Capture.cancel("reset")

    local runtime, observed = makeRuntime()
    local completed = nil
    local result, err = Capture.start({
        zoteroBundleId = "org.zotero.zotero",
        safariBundleId = "com.apple.Safari",
        collectionKey = "COLL",
        courseName = "Dynamics",
        onComplete = function(ok, value)
            completed = { ok = ok, value = value }
        end,
    }, runtime)

    assertNil(err, "course capture start error")
    assertTruthy(result and result.started, "course capture started")
    observed.advanceAndTick(3)

    assertTruthy(completed and completed.ok, "course capture completion")
    local payload = observed.helperPayload()
    assertEqual(payload.itemKeys[1], "NEW1", "captured item key")
    assertEqual(payload.collectionKey, "COLL", "captured course collection")
    assertEqual(payload.unfiled, false, "captured course mode")

    local unfiledRuntime, unfiledObserved = makeRuntime()
    local unfiledComplete = nil
    local unfiledResult, unfiledErr = Capture.start({
        zoteroBundleId = "org.zotero.zotero",
        safariBundleId = "com.apple.Safari",
        unfiled = true,
        onComplete = function(ok, value)
            unfiledComplete = { ok = ok, value = value }
        end,
    }, unfiledRuntime)

    assertNil(unfiledErr, "unfiled capture start error")
    assertTruthy(unfiledResult and unfiledResult.started, "unfiled capture started")
    unfiledObserved.advanceAndTick(3)

    assertTruthy(unfiledComplete and unfiledComplete.ok, "unfiled capture completion")
    local unfiledPayload = unfiledObserved.helperPayload()
    assertEqual(unfiledPayload.unfiled, true, "explicit unfiled mode")
    assertEqual(unfiledPayload.collectionKey, nil, "explicit unfiled collection")

    print("Reference capture tests passed.")
    return true
end

return Tests
