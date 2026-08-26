local Editor = {}

local Config = require("course.config")
local References = require("course.references")
local Registry = require("course.registry")
local Textbook = require("course.textbook")
local Timetable = require("course.timetable")
local Util = require("course.util")

Editor._chooser = nil

local function runtimeFunction(runtime, name, fallback)
    if type(runtime) == "table" and type(runtime[name]) == "function" then
        return runtime[name]
    end
    return fallback
end

local function defaultNotify(message)
    hs.alert.show(message)
end

local function notify(runtime, message)
    runtimeFunction(runtime, "notify", defaultNotify)(message)
end

local function courseLabel(course)
    return course.shortName or course.name or course.id or "course"
end

local function readRaw(course)
    if type(course) ~= "table" or not Util.isNonEmptyString(course.configPath) then
        return nil, "Course editor requires a persisted course configuration."
    end

    return Util.readJson(course.configPath)
end

local function reloadCourse(course)
    local reloaded, reloadErr = Registry.reload()

    if not reloaded then
        return nil, reloadErr
    end

    return Registry.getCourse(course.id)
end

local function writeRaw(course, raw)
    local previous, previousErr = Util.readFile(course.configPath)

    if not previous then
        return nil, "Could not read course config for rollback: " .. tostring(previousErr)
    end

    local encoded = hs.json.encode(raw, true) .. "\n"
    local wrote, writeErr = Util.writeFileAtomic(course.configPath, encoded)

    if not wrote then
        return nil, "Could not update course configuration: " .. tostring(writeErr)
    end

    local validated, validationErr = Config.loadSemester(course.semesterId)

    if not validated then
        local rollbackOk, rollbackErr = Util.writeFileAtomic(course.configPath, previous)
        local message = "Edited course configuration failed validation and was rolled back: "
            .. tostring(validationErr)

        if not rollbackOk then
            message = message .. " Config rollback also failed: " .. tostring(rollbackErr)
        end

        return nil, message
    end

    local refreshed, reloadErr = reloadCourse(course)

    if not refreshed then
        return nil, "Course was saved but registry reload failed: " .. tostring(reloadErr)
    end

    return refreshed
end

local function promptText(title, message, defaultValue)
    local button, value = hs.dialog.textPrompt(
        title,
        message,
        defaultValue or "",
        "Save",
        "Cancel"
    )

    if button ~= "Save" then
        return nil, true
    end

    return Util.trim(value or ""), false
end

local function editRequiredString(course, field, label, validator, runtime)
    local raw, rawErr = readRaw(course)

    if not raw then
        return nil, rawErr
    end

    while true do
        local value, cancelled = promptText(
            "Edit Course — " .. courseLabel(course),
            label,
            raw[field] or ""
        )

        if cancelled then
            return { cancelled = true, course = course }
        end

        if not Util.isNonEmptyString(value) then
            notify(runtime, label .. " cannot be empty.")
        else
            local valid, validationErr = true, nil

            if type(validator) == "function" then
                valid, validationErr = validator(value)
            end

            if valid then
                raw[field] = value
                local refreshed, saveErr = writeRaw(course, raw)

                if not refreshed then
                    return nil, saveErr
                end

                return { cancelled = false, course = refreshed, field = field }
            end

            notify(runtime, validationErr or ("Invalid " .. label .. "."))
        end
    end
end

local function validateUrl(value)
    if value:match("^https?://") then
        return true
    end

    return nil, "Course webpage must begin with http:// or https://."
end

local function editTimetable(course, runtime)
    local raw, rawErr = readRaw(course)

    if not raw then
        return nil, rawErr
    end

    while true do
        local timetableText, cancelled = promptText(
            "Edit Course — " .. courseLabel(course),
            "Weekly timetable\n\n"
                .. "Use semicolon-separated slots, e.g. Mon 12-16; Thu 8-10.\n"
                .. "Blank removes all fixed weekly slots.\n\n"
                .. "Conflicts with other courses are allowed; automatic timetable context will refuse to guess while more than one course is active.",
            Timetable.format(raw.timetable or {})
        )

        if cancelled then
            return { cancelled = true, course = course }
        end

        local timetable, timetableErr = Timetable.parse(timetableText)

        if not timetable then
            notify(runtime, timetableErr)
        else
            local courses = Registry.allCourses() or {}
            local conflicts = Timetable.conflicts(timetable, courses, course.id)

            if #conflicts > 0 then
                local summary = Timetable.conflictSummary(conflicts, course.name)
                local choice = hs.dialog.blockAlert(
                    "Timetable conflict",
                    "This is allowed, but timetable-only course resolution will be ambiguous during the overlap.\n\n"
                        .. tostring(summary),
                    "Save Anyway",
                    "Edit Again"
                )

                if choice ~= "Save Anyway" then
                    goto continue
                end
            end

            raw.timetable = timetable
            local refreshed, saveErr = writeRaw(course, raw)

            if not refreshed then
                return nil, saveErr
            end

            return { cancelled = false, course = refreshed, field = "timetable" }
        end

        ::continue::
    end
end

local function configuredCollectionKey(course)
    return course.zotero
        and Util.isNonEmptyString(course.zotero.collectionKey)
        and Util.trim(course.zotero.collectionKey)
        or nil
end

function Editor.repairReferences(course, options, runtime)
    options = options or {}

    if type(course) ~= "table" then
        return nil, "Reference repair requires a course."
    end

    local global = options.global

    if type(global) ~= "table" then
        local globalErr
        global, globalErr = Config.loadGlobal()

        if not global then
            return nil, globalErr
        end
    end

    local result, provisionErr = References.provisionCourse({
        semesterName = course.semesterName,
        courseName = course.name,
        collectionKey = configuredCollectionKey(course),
        exportPath = course.referencesBib,
        zoteroBundleId = global.zoteroBundleId,
    }, runtime)

    if not result then
        return nil, provisionErr
    end

    local raw, rawErr = readRaw(course)

    if not raw then
        return nil, rawErr
    end

    raw.zotero = type(raw.zotero) == "table" and raw.zotero or {}
    raw.zotero.collectionKey = result.collectionKey

    local refreshed, saveErr = writeRaw(course, raw)

    if not refreshed then
        return nil, saveErr
    end

    local exportReady, exportErr = References.waitForExportFile(
        refreshed.referencesBib,
        runtime
    )

    if not exportReady then
        return nil,
            "Zotero collection identity was saved, but the bibliography export is not ready: "
                .. tostring(exportErr)
    end

    return {
        cancelled = false,
        course = refreshed,
        collectionKey = result.collectionKey,
        exportPath = refreshed.referencesBib,
        reused = result.reused == true,
    }
end

local function defaultConfirmSemesterReferenceRepair(courses)
    local choice = hs.dialog.blockAlert(
        "Repair Semester References",
        "Re-provision Zotero collections and Better BibLaTeX auto-exports for "
            .. tostring(#(courses or {}))
            .. " courses in the active semester?\n\n"
            .. "Existing stable collection identities are reused. Course files are not recreated.",
        "Repair",
        "Cancel"
    )

    return choice == "Repair"
end

function Editor.repairSemesterReferences(options, runtime)
    options = options or {}

    local global, globalErr = Config.loadGlobal()

    if not global then
        return nil, globalErr
    end

    local courses, coursesErr = Registry.allCourses()

    if not courses then
        return nil, coursesErr
    end

    if options.confirm ~= false then
        local confirm = runtimeFunction(
            runtime,
            "confirmSemesterReferenceRepair",
            defaultConfirmSemesterReferenceRepair
        )
        local ok, confirmed = pcall(confirm, courses)

        if not ok then
            return nil, "Could not confirm reference repair: " .. tostring(confirmed)
        end

        if confirmed ~= true then
            return { cancelled = true, repaired = {}, errors = {}, ok = true }
        end
    end

    local repaired = {}
    local errors = {}

    for _, course in ipairs(courses) do
        local result, err = Editor.repairReferences(
            course,
            { global = global },
            runtime
        )

        if result then
            table.insert(repaired, result.course.id)
        else
            table.insert(
                errors,
                (course.shortName or course.name or course.id) .. ": " .. tostring(err)
            )
        end
    end

    return {
        repaired = repaired,
        errors = errors,
        ok = #errors == 0,
    }
end

function Editor.setTextbook(course, options, runtime)
    options = options or {}

    local global = options.global

    if type(global) ~= "table" then
        local globalErr
        global, globalErr = Config.loadGlobal()

        if not global then
            return nil, globalErr
        end
    end

    local current = course

    if not configuredCollectionKey(current) then
        local repaired, repairErr = Editor.repairReferences(
            current,
            { global = global },
            runtime
        )

        if not repaired then
            return nil,
                "References must be provisioned before adding a textbook: "
                    .. tostring(repairErr)
        end

        current = repaired.course
    end

    local textbookOptions = {}

    for key, value in pairs(options) do
        textbookOptions[key] = value
    end

    textbookOptions.global = global

    local result, textbookErr = Textbook.set(
        current,
        textbookOptions,
        runtime
    )

    if not result then
        return nil, textbookErr
    end

    if result.cancelled == true then
        return result
    end

    local refreshed, reloadErr = reloadCourse(current)

    if not refreshed then
        return nil,
            "Textbook was updated but registry reload failed: " .. tostring(reloadErr)
    end

    result.course = refreshed
    return result
end

local function fieldChoices(course)
    local nameLocked = configuredCollectionKey(course) ~= nil
    local referenceStatus = configuredCollectionKey(course)
        and "Provisioned · repair/recreate export"
        or "Not provisioned · create collection + references.bib"

    return {
        {
            text = "Full course name",
            subText = nameLocked
                and "Locked after Zotero collection identity exists; short name remains editable"
                or tostring(course.name),
            field = "name",
            valid = not nameLocked,
        },
        {
            text = "Short name",
            subText = tostring(course.shortName),
            field = "shortName",
        },
        {
            text = "Course code",
            subText = tostring(course.code),
            field = "code",
        },
        {
            text = "Course webpage",
            subText = tostring(course.courseUrl),
            field = "courseUrl",
        },
        {
            text = "Timetable",
            subText = Timetable.format(course.timetable) ~= ""
                and Timetable.format(course.timetable)
                or "No fixed weekly slots",
            field = "timetable",
        },
        {
            text = Util.isNonEmptyString(course.bookSource)
                and "Change textbook…"
                or "Add textbook…",
            subText = course.bookSource or "No textbook configured",
            field = "textbook",
        },
        {
            text = "Repair references / Zotero…",
            subText = referenceStatus,
            field = "references",
        },
        {
            text = "Course ID / folder slug",
            subText = tostring(course.id) .. " · structural identity (not editable here)",
            valid = false,
            field = "identity",
        },
    }
end

local function runField(course, field, runtime)
    if field == "name" then
        return editRequiredString(course, "name", "Full course name", nil, runtime)
    elseif field == "shortName" then
        return editRequiredString(course, "shortName", "Short course name", nil, runtime)
    elseif field == "code" then
        return editRequiredString(course, "code", "Course code", nil, runtime)
    elseif field == "courseUrl" then
        return editRequiredString(course, "courseUrl", "Course webpage URL", validateUrl, runtime)
    elseif field == "timetable" then
        return editTimetable(course, runtime)
    elseif field == "textbook" then
        return Editor.setTextbook(course, nil, runtime)
    elseif field == "references" then
        return Editor.repairReferences(course, nil, runtime)
    end

    return nil, "Unknown editable course field: " .. tostring(field)
end

function Editor.show(course, options, runtime)
    options = options or {}

    if type(course) ~= "table" or not Util.isNonEmptyString(course.id) then
        return nil, "Edit Course requires a course."
    end

    local chooser = hs.chooser.new(function(choice)
        Editor._chooser = nil

        if not choice then
            return
        end

        local result, err = runField(course, choice.field, runtime)

        if not result then
            notify(runtime, err or "Course edit failed.")
            return
        end

        if result.cancelled == true then
            return
        end

        if choice.field == "references" then
            notify(runtime, "References repaired · " .. courseLabel(result.course))
        elseif choice.field == "textbook" then
            if result.bibliographyReady == false then
                if result.bibliographyError then
                    print(
                        "Textbook bibliography verification warning: "
                            .. tostring(result.bibliographyError)
                    )
                end

                notify(runtime, "Textbook updated · references.bib still pending · " .. courseLabel(result.course))
            else
                notify(runtime, "Textbook updated · " .. courseLabel(result.course))
            end
        else
            notify(runtime, "Course updated · " .. courseLabel(result.course))
        end
    end)

    chooser:choices(fieldChoices(course))
    chooser:placeholderText("Edit Course · " .. courseLabel(course))
    chooser:searchSubText(true)
    chooser:rows(8)
    chooser:width(46)
    chooser:invalidCallback(function(choice)
        notify(
            runtime,
            choice and choice.subText or "This course field is not editable here."
        )
    end)
    chooser:show()

    Editor._chooser = chooser

    return {
        deferred = true,
        course = course,
    }
end

return Editor
