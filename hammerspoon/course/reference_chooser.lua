local ReferenceChooser = {}

ReferenceChooser._chooser = nil
ReferenceChooser._onChoose = nil

local function choiceFor(item)
    local author = item.author or "Unknown"
    local year = item.year or "n.d."
    local title = item.title or "Untitled"
    local citationKey = item.citationKey or "?"

    return {
        text = string.format("%s · %s", author, year),
        subText = string.format("%s  [%s]", title, citationKey),
        item = item,
        searchText = table.concat({
            author,
            year,
            title,
            citationKey,
        }, " "),
    }
end

local function ensureChooser()
    if ReferenceChooser._chooser then
        return ReferenceChooser._chooser
    end

    local chooser = hs.chooser.new(function(choice)
        if not choice or type(choice.item) ~= "table" then
            return
        end

        local callback = ReferenceChooser._onChoose

        if type(callback) == "function" then
            callback(choice.item)
        end
    end)

    chooser:searchSubText(true)
    chooser:width(52)
    chooser:rows(12)
    ReferenceChooser._chooser = chooser
    return chooser
end

function ReferenceChooser.show(items, options)
    options = options or {}

    if type(items) ~= "table" then
        return nil, "Reference chooser requires a table of normalized Zotero items."
    end

    if #items == 0 then
        return nil, "No references found in this scope."
    end

    local choices = {}

    for _, item in ipairs(items) do
        table.insert(choices, choiceFor(item))
    end

    ReferenceChooser._onChoose = options.onChoose
    local chooser = ensureChooser()
    chooser:choices(choices)
    chooser:placeholderText(options.title or "Search References")
    chooser:query("")
    chooser:show()

    return {
        count = #items,
        scope = options.scope,
    }
end

function ReferenceChooser.stop()
    if ReferenceChooser._chooser then
        ReferenceChooser._chooser:delete()
    end

    ReferenceChooser._chooser = nil
    ReferenceChooser._onChoose = nil
end

return ReferenceChooser
