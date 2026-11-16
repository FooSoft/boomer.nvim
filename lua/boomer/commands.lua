-- Slash commands: parsing, the built-in command table, user prompt templates,
-- help text and completion candidates. Execution lives in boomer.init.
--
-- Three sources share one namespace, in priority order: user commands
-- (config `commands`, where `false` hides a builtin), builtins, and commands
-- the agent advertises (sent to it as prompt text).
local M = {}

-- `gate` names the precondition checked before the command runs (see
-- blocked() in init.lua); `complete` the kind of argument it completes.
-- `ex` commands are only available as `:Boomer {name}`, not from the prompt.
-- `defer` commands run the agent's command of the same name if it has one,
-- and then show and complete its hint.
M.builtins = {
    model = { desc = 'Choose the model', hint = '[model]', gate = 'idle', complete = 'model' },
    effort = {
        desc = 'Choose the reasoning effort',
        hint = '[level]',
        gate = 'idle',
        complete = 'effort',
    },
    mode = {
        desc = 'Choose the session mode (such as Agent or Plan)',
        hint = '[mode]',
        gate = 'idle',
        complete = 'mode',
    },
    resume = { desc = 'Load a saved session', hint = '[id]', gate = 'switch', complete = 'session' },
    new = { desc = 'Start a new session', gate = 'switch' },
    usage = { desc = 'Show context, token and cost usage', gate = 'session' },
    settings = { desc = 'Change any session setting', gate = 'idle' },
    permissions = {
        desc = 'Choose what the agent may do without asking',
        hint = '[preset]',
        gate = 'idle',
        complete = 'permissions',
        defer = true,
    },
    compact = {
        desc = 'Summarize the conversation to free context',
        hint = '[focus]',
        gate = 'idle',
        defer = true,
    },
    agent = {
        desc = 'Switch to another agent',
        hint = '[name]',
        gate = 'agent',
        complete = 'agent',
    },
    help = { desc = 'List commands', gate = 'none' },
    cancel = { desc = 'Cancel the active turn', gate = 'none', ex = true },
    close = { desc = 'Stop the agent and wipe the chat', gate = 'none', ex = true },
}

-- nil for plain text; { text = ... } for `//text` (sent as `/text`);
-- { name = ..., args = ... } for a command. Only the start of the draft counts,
-- and paths such as /etc/hosts stay text.
function M.parse(text)
    if text:sub(1, 2) == '//' then
        return { text = text:sub(2) }
    end
    local name, args = text:match('^/([^%s/]+)(.*)$')
    if name and (args == '' or args:match('^%s')) then
        return { name = name, args = vim.trim(args) }
    end
end

-- The literal choices in an agent's argument hint, such as Copilot's
-- `[default|assisted|allow-all|show]`; placeholders like `<objective>` are
-- skipped.
---@param hint? string
---@return string[]
function M.hint_values(hint)
    local out = {}
    local group = type(hint) == 'string' and hint:match('^%s*%[([^%]]*)%]')
    if group and group:find('|', 1, true) then
        for value in vim.gsplit(group, '|', { plain = true }) do
            value = vim.trim(value)
            if value:match('^[%w][%w._-]*$') then
                out[#out + 1] = value
            end
        end
    end
    return out
end

-- Expand a user `prompt`: a string with $ARGUMENTS or a function(args, ctx).
function M.expand(spec, args, ctx)
    if type(spec.prompt) == 'function' then
        return spec.prompt(args, ctx)
    end
    local text, n = spec.prompt:gsub('%$ARGUMENTS', function()
        return args
    end)
    if n == 0 and args ~= '' then
        text = text .. '\n\n' .. args
    end
    return text
end

-- Every command visible to a chat: { name, desc, hint, source, spec }, sorted
-- by name within builtin, user and agent groups. `typed` (the prompt, not
-- :Boomer) hides Ex-only commands.
---@param user table<string, table|false> config `commands`
---@param agent table<string, table> Commands the agent advertised, by name.
---@param typed boolean
---@return { name: string, desc: string?, hint: string?, source: 'builtin'|'user'|'agent', spec: table }[]
function M.list(user, agent, typed)
    local out, seen = {}, {}
    local function add(name, desc, hint, source, spec)
        if not seen[name] then
            seen[name] = true
            out[#out + 1] = { name = name, desc = desc, hint = hint, source = source, spec = spec }
        end
    end
    local function sorted(t)
        local keys = vim.tbl_keys(t)
        table.sort(keys)
        return keys
    end
    for _, name in ipairs(sorted(user)) do
        if user[name] then
            add(name, user[name].desc, nil, 'user', user[name])
        end
    end
    for _, name in ipairs(sorted(M.builtins)) do
        local b = M.builtins[name]
        if user[name] == nil and not (typed and b.ex) then
            local hint = b.defer and agent[name] and agent[name].hint or b.hint
            add(name, b.desc, hint, 'builtin', b)
        end
    end
    for _, name in ipairs(sorted(agent)) do
        add(name, agent[name].desc, agent[name].hint, 'agent', agent[name])
    end
    table.sort(out, function(a, b)
        local order = { builtin = 1, user = 2, agent = 3 }
        if a.source ~= b.source then
            return order[a.source] < order[b.source]
        end
        return a.name < b.name
    end)
    return out
end

-- The command named `name` as list() describes it, or nil.
function M.find(user, agent, name, typed)
    for _, item in ipairs(M.list(user, agent, typed)) do
        if item.name == name then
            return item
        end
    end
end

-- /help lines: one per command (first line of its description), grouped by source.
function M.help(list)
    local lines, last = {}, nil
    local titles = { builtin = 'Commands:', user = 'User commands:', agent = 'Agent commands:' }
    for _, item in ipairs(list) do
        if item.source ~= last then
            lines[#lines + 1] = titles[item.source]
            last = item.source
        end
        local desc = item.desc and (' - ' .. item.desc:gsub('%s*\n.*', '')) or ''
        lines[#lines + 1] = '/' .. item.name .. (item.hint and (' ' .. item.hint) or '') .. desc
    end
    lines[#lines + 1] = 'Start with // to send text that begins with /.'
    return lines
end

return M
