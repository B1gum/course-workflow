local Tests = {}

local References = require("course.references")

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

local ITEM1 = {
    key = "ITEM1",
    data = {
        key = "ITEM1",
        itemType = "book",
        title = "Contact Mechanics",
        date = "1985",
        DOI = "10.1000/contact",
        url = "https://example.test/contact",
        creators = {
            { creatorType = "author", firstName = "K. L.", lastName = "Johnson" },
        },
    },
}

local ITEM2 = {
    key = "ITEM2",
    data = {
        key = "ITEM2",
        itemType = "journalArticle",
        title = "Fatigue Example",
        date = "2025-04",
        creators = {
            { creatorType = "author", firstName = "A.", lastName = "Smith" },
        },
    },
}

local CHILD = {
    key = "ATT1",
    data = {
        key = "ATT1",
        itemType = "attachment",
        contentType = "application/pdf",
        filename = "Contact Mechanics.pdf",
    },
}

local function rpcResponse(result)
    return 200, hs.json.encode({
        jsonrpc = "2.0",
        id = 1,
        result = result,
    }), {}
end

local function makeRuntime(options)
    options = options or {}
    local observed = {
        urls = {},
        files = {},
        helperPosts = {},
    }

    local runtime = {
        launchBundle = function()
            fail("Zotero should already be ready in reference tests")
        end,
        sleep = function() end,
        httpPost = function(url, body)
            local payload = hs.json.decode(body)

            if url:find("/course-workflow/assign-capture", 1, true) then
                table.insert(observed.helperPosts, payload)
                return 200, hs.json.encode({
                    count = #payload.itemKeys,
                    itemKeys = payload.itemKeys,
                    changed = payload.itemKeys,
                    unfiled = payload.unfiled == true,
                    collectionKey = payload.collectionKey,
                }), {}
            end

            if payload.method == "api.ready" then
                return rpcResponse({
                    betterbibtex = "7.0-test",
                    zotero = "9.0-test",
                })
            end

            if payload.method == "item.citationkey" then
                local keys = payload.params[1]
                local result = {}

                for _, key in ipairs(keys) do
                    if key == "ITEM1" then
                        result[key] = "johnson1985contactmechanics"
                    elseif key == "ITEM2" then
                        result[key] = "smith2025fatigue"
                    end
                end

                return rpcResponse(result)
            end

            return 500, hs.json.encode({ error = "unexpected RPC method" }), {}
        end,
        httpGet = function(url)
            if url:find("/course-workflow/ready", 1, true) then
                return 200, hs.json.encode({ ready = true, version = "1.1.0", zotero = "9.0-test" }), {}
            end

            if url:find("/collections/COLL/items/top", 1, true) then
                return 200, hs.json.encode({ ITEM1, ITEM2, CHILD }), {}
            end

            if url:find("/items/top", 1, true) then
                return 200, hs.json.encode({ ITEM1, ITEM2, CHILD }), {}
            end

            if url:find("/collections/COLL?v=3", 1, true) then
                return 200, hs.json.encode({
                    key = "COLL",
                    data = { key = "COLL", name = "Dynamics" },
                }), {}
            end

            if url:find("/items/ITEM1/children", 1, true) then
                local children = options.missingPdf and {} or { CHILD }
                return 200, hs.json.encode(children), {}
            end

            if url:find("/items/ITEM1?v=3", 1, true) then
                return 200, hs.json.encode(ITEM1), {}
            end

            if url:find("/items/ATT1/file/view/url", 1, true) then
                return 200, "file:///tmp/Contact%20Mechanics.pdf", {}
            end

            return 404, "not found", {}
        end,
        fileMode = function(path)
            if path == "/tmp/Contact Mechanics.pdf" and not options.missingPdf then
                return "file"
            end
            return nil
        end,
        openFileWithBundle = function(path, bundleId)
            table.insert(observed.files, { path = path, bundleId = bundleId })
            return true
        end,
        openURLWithBundle = function(url, bundleId)
            table.insert(observed.urls, { url = url, bundleId = bundleId })
            return true
        end,
    }

    return runtime, observed
end

local function serviceOptions()
    return {
        zoteroBundleId = "org.zotero.zotero",
        skimBundleId = "net.sourceforge.skim-app.skim",
    }
end

function Tests.run()
    local course = {
        id = "dynamics",
        name = "Dynamics",
        shortName = "Dynamics",
        zotero = { collectionKey = "COLL" },
    }

    local runtime, observed = makeRuntime()

    local items, itemsErr = References.itemsForCourse(course, serviceOptions(), runtime)
    assertNil(itemsErr, "course items error")
    assertEqual(#items, 2, "normalized item count")
    assertEqual(items[1].itemKey, "ITEM1", "first item key")
    assertEqual(items[1].citationKey, "johnson1985contactmechanics", "first citation key")
    assertEqual(items[1].author, "Johnson", "first author")
    assertEqual(items[1].year, "1985", "first year")
    assertEqual(items[1].collectionKey, "COLL", "collection identity")
    assertEqual(items[1].doi, "10.1000/contact", "DOI normalization")

    local collection, collectionErr = References.openCollection(
        course,
        serviceOptions(),
        runtime
    )
    assertNil(collectionErr, "open collection error")
    assertEqual(collection.collectionKey, "COLL", "opened collection key")
    assertEqual(
        observed.urls[#observed.urls].url,
        "zotero://select/library/collections/COLL",
        "stable collection URI"
    )

    local opened, openErr = References.openReference(
        { itemKey = "ITEM1" },
        serviceOptions(),
        runtime
    )
    assertNil(openErr, "open local PDF error")
    assertEqual(opened.opened, "skim", "local PDF open target")
    assertEqual(opened.path, "/tmp/Contact Mechanics.pdf", "decoded PDF path")
    assertEqual(observed.files[1].bundleId, "net.sourceforge.skim-app.skim", "Skim bundle")

    local resolved, resolveErr = References.resolveCitationKey(
        "johnson1985contactmechanics",
        serviceOptions(),
        runtime
    )
    assertNil(resolveErr, "citation-key resolution error")
    assertEqual(resolved.itemKey, "ITEM1", "citation-key item")

    local paged, pageErr = References.openCitedPage(
        "johnson1985contactmechanics",
        42,
        serviceOptions(),
        runtime
    )
    assertNil(pageErr, "cited-page error")
    assertEqual(paged.opened, "skim", "cited-page target")
    assertEqual(paged.page, 42, "cited-page number")
    assertEqual(
        observed.urls[#observed.urls].url,
        "skim:///tmp/Contact%20Mechanics.pdf#page=42",
        "Skim cited-page URI"
    )

    local assigned, assignErr = References.assignCapturedItems(
        { "ITEM1", "ITEM2" },
        { collectionKey = "COLL" },
        runtime
    )
    assertNil(assignErr, "capture assignment error")
    assertEqual(assigned.count, 2, "capture assignment count")
    assertEqual(observed.helperPosts[1].collectionKey, "COLL", "capture collection key")
    assertEqual(observed.helperPosts[1].unfiled, false, "capture course mode")

    local unfiled, unfiledErr = References.assignCapturedItems(
        { "ITEM2" },
        { unfiled = true },
        runtime
    )
    assertNil(unfiledErr, "unfiled assignment error")
    assertEqual(unfiled.unfiled, true, "unfiled helper result")
    assertEqual(observed.helperPosts[2].unfiled, true, "unfiled helper payload")

    local fallbackRuntime, fallbackObserved = makeRuntime({ missingPdf = true })
    local fallback, fallbackErr = References.openReference(
        { itemKey = "ITEM1" },
        serviceOptions(),
        fallbackRuntime
    )
    assertNil(fallbackErr, "missing-PDF fallback error")
    assertEqual(fallback.opened, "zotero", "missing-PDF fallback target")
    assertEqual(fallback.fallbackUrl, "https://doi.org/10.1000/contact", "missing-PDF DOI fallback")
    assertTruthy(fallback.reason, "missing-PDF reason")
    assertEqual(
        fallbackObserved.urls[#fallbackObserved.urls].url,
        "zotero://select/library/items/ITEM1",
        "missing-PDF Zotero item URI"
    )

    print("Reference service tests passed.")
    return true
end

return Tests
