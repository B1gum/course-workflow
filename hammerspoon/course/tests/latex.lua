local Tests = {}

local LaTeX = require("course.latex")

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

local function runCases()
    local cases = {}

    local function case(name, fn)
        table.insert(cases, { name = name, fn = fn })
    end

    case("range parser accepts normal and en-dash ranges", function()
        local first, last = LaTeX.parseRange("3-8")
        assertEqual(first, 3, "normal range first")
        assertEqual(last, 8, "normal range last")

        first, last = LaTeX.parseRange("5–10")
        assertEqual(first, 5, "en-dash range first")
        assertEqual(last, 10, "en-dash range last")
    end)

    case("range parser rejects reversed ranges", function()
        local first, err = LaTeX.parseRange("8-3")
        assertNil(first, "reversed range result")
        assertEqual(err, "Lecture range start cannot be after its end.", "reversed range error")
    end)

    case("selection parser expands ranges and removes duplicates", function()
        local numbers, err = LaTeX.parseSelection("1, 3-5, 4, 7")
        assertNil(err, "selection error")
        assertEqual(#numbers, 5, "selection count")
        assertEqual(numbers[1], 1, "selection 1")
        assertEqual(numbers[2], 3, "selection 2")
        assertEqual(numbers[3], 4, "selection 3")
        assertEqual(numbers[4], 5, "selection 4")
        assertEqual(numbers[5], 7, "selection 5")
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
        print("✗ LaTeX tests failed")
        print(resultOrError)
        return nil, resultOrError
    end

    print(string.format("LaTeX tests passed: %d/%d", resultOrError, total))
    return true
end

return Tests
