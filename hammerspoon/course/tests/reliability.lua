local Tests = {}

local Util = require("course.util")

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

local function removeTree(root)
    if hs.fs.attributes(root, "mode") ~= "directory" then
        return
    end

    for name in hs.fs.dir(root) do
        if name ~= "." and name ~= ".." then
            local path = Util.joinPath(root, name)
            if hs.fs.attributes(path, "mode") == "directory" then
                removeTree(path)
            else
                pcall(os.remove, path)
            end
        end
    end

    pcall(os.remove, root)
end

local function runCases()
    local cases = {}

    local function case(name, fn)
        table.insert(cases, { name = name, fn = fn })
    end

    case("atomic writes support spaces punctuation and Danish characters", function()
        local root = string.format(
            "/tmp/noah-course-workflow-reliability-%d-%06d",
            os.time(),
            math.random(0, 999999)
        )
        local ok = hs.fs.mkdir(root)
        assertTruthy(ok, "temporary directory")

        local path = Util.joinPath(root, "øvelse (1) - data.txt")
        local wrote, writeErr = Util.writeFileAtomic(path, "første")
        assertTruthy(wrote, writeErr or "first atomic write")

        local contents, readErr = Util.readFile(path)
        assertTruthy(contents, readErr or "first atomic read")
        assertEqual(contents, "første", "first atomic contents")

        wrote, writeErr = Util.writeFileAtomic(path, "anden")
        assertTruthy(wrote, writeErr or "replacement atomic write")

        contents, readErr = Util.readFile(path)
        assertTruthy(contents, readErr or "replacement atomic read")
        assertEqual(contents, "anden", "replacement atomic contents")

        removeTree(root)
    end)

    case("atomic write rejects a missing parent directory", function()
        local path = string.format(
            "/tmp/noah-course-workflow-missing-%d-%06d/file.txt",
            os.time(),
            math.random(0, 999999)
        )
        local wrote, err = Util.writeFileAtomic(path, "data")

        assertNil(wrote, "missing-parent result")
        assertTruthy(
            type(err) == "string"
                and err:find("parent directory does not exist", 1, true) ~= nil,
            "missing-parent error"
        )
    end)

    local passed = 0

    for _, testCase in ipairs(cases) do
        testCase.fn()
        passed = passed + 1
        print("✓ " .. testCase.name)
    end

    return passed, #cases
end

function Tests.run()
    local ok, resultOrError, total = xpcall(function()
        local passed, count = runCases()
        return passed, count
    end, debug.traceback)

    if not ok then
        print("✗ Reliability tests failed")
        print(resultOrError)
        return nil, resultOrError
    end

    print(string.format("Reliability tests passed: %d/%d", resultOrError, total))
    return true
end

return Tests
