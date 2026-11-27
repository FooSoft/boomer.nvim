-- Helpers shared by the adapters and the chat.
--
-- Adapters describe their session settings in one backend-neutral shape, so
-- the chat can list, complete and change them without knowing the protocol.

---@class boomer.Choice
---@field label string Shown to the user; nested ACP groups read "Group / Name".
---@field value any Sent back to the agent (string, or boolean for toggles).

---@class boomer.Setting
---@field id string Adapter-specific ID passed to `client:configure()`.
---@field label string
---@field category? string One of the values of `M.categories`, or another agent-defined one.
---@field current any Current value (matches a choice's `value`).
---@field choices boomer.Choice[]

---A file the agent changes (or asks to change), shown as a unified diff.
---@class boomer.Diff
---@field from? string Path before the change; nil for an added file.
---@field to? string Path after the change; nil for a deleted file.
---@field text string Hunks ("@@" lines and their bodies), without file headers.

local M = {}

-- Setting categories by the name Boomer uses for them. The names on the right
-- are ACP's config option categories; the Codex adapter reports the same ones.
M.categories = {
    model = 'model',
    effort = 'thought_level',
    mode = 'mode',
    permissions = 'permissions',
}

---@param list boomer.Setting[]?
---@param category string
---@return boomer.Setting?
function M.find(list, category)
    for _, s in ipairs(list or {}) do
        if s.category == category then
            return s
        end
    end
end

-- Match what the user typed against choice values first, then labels
-- (case-insensitive; "Two" also matches the grouped label "Family / Two").
---@param setting boomer.Setting
---@param input string
---@return boomer.Choice?
function M.choice(setting, input)
    for _, c in ipairs(setting.choices) do
        if tostring(c.value) == input then
            return c
        end
    end
    local lower = input:lower()
    for _, c in ipairs(setting.choices) do
        local label = c.label:lower()
        if label == lower or label:match(' / (.-)$') == lower then
            return c
        end
    end
end

-- What to type to select `choice` (the argument of /model, /mode, ...):
-- its value, or its label where the value is a URI (Copilot's mode IDs).
---@param choice boomer.Choice
---@return string
function M.argument(choice)
    local value = tostring(choice.value)
    return value:find('://', 1, true) and choice.label:lower() or value
end

-- Display label of the current value (without its group), or the raw value.
---@param setting boomer.Setting
---@return string?
function M.current_label(setting)
    for _, c in ipairs(setting.choices) do
        if c.value == setting.current then
            return (c.label:gsub('^.* / ', ''))
        end
    end
    return setting.current ~= nil and tostring(setting.current) or nil
end

-- Hunks turning the file text `old` into `new`; '' when they are equal.
---@param old string
---@param new string
---@return string
function M.hunks(old, new)
    return vim.text.diff(old, new, { ctxlen = 3 }) --[[@as string]]
end

-- The diffs that show something: an edit without hunks is dropped (added,
-- deleted and moved files are worth a header). nil when none is left.
---@param list boomer.Diff[]
---@return boomer.Diff[]?
function M.shown(list)
    local out = vim.tbl_filter(function(d)
        return d.from ~= d.to or d.text:find('%S') ~= nil
    end, list)
    return #out > 0 and out or nil
end

-- A Markdown code fence that `lines` cannot close: longer than any run of
-- backticks in them, and at least three.
---@param lines string[]
---@return string
function M.fence(lines)
    local ticks = 2
    for _, l in ipairs(lines) do
        for run in l:gmatch('`+') do
            ticks = math.max(ticks, #run)
        end
    end
    return ('`'):rep(ticks + 1)
end

-- Compact token counts: 950, 12.3k, 1.2M.
---@param n any
---@return string
function M.tokens(n)
    if type(n) ~= 'number' then
        return '?'
    elseif n >= 1e6 then
        return ('%.1fM'):format(n / 1e6)
    elseif n >= 1e3 then
        return ('%.1fk'):format(n / 1e3)
    end
    return tostring(math.floor(n))
end

-- Rounded share of the context window in use, or nil if the size is unknown.
---@param ctx { used: number?, size: number? }
---@return integer?
function M.percent(ctx)
    if type(ctx.used) == 'number' and type(ctx.size) == 'number' and ctx.size > 0 then
        return math.floor(ctx.used / ctx.size * 100 + 0.5)
    end
end

return M
