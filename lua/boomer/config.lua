-- Options and agent profiles.
--
-- A profile names a protocol adapter (boomer.codex or boomer.acp) and the
-- process that speaks it. Built-in profiles are merged with the user's,
-- field by field. Options are validated eagerly so mistakes surface in setup().

---@class boomer.Profile
---@field name string Profile name (set by resolve()).
---@field protocol 'codex'|'acp'
---@field command string Executable.
---@field args string[]
---@field env? table<string, string> Added to Neovim's environment.
---@field cwd string Absolute working directory: Neovim's (set by resolve()).
---@field label string Label of the agent's messages (set by resolve()).
---@field model? string Default model for new sessions (ID or name).
---@field effort? string Default reasoning effort for new sessions.
---@field mode? string Default mode for new sessions.
---@field options table<string, any> ACP config option defaults for new sessions.

local M = {}

-- Adapter module of each protocol.
M.protocols = { codex = 'boomer.codex', acp = 'boomer.acp' }

-- ACP commands follow the ACP registry (agentclientprotocol.com/registry).
local builtin = {
    codex = { protocol = 'codex', command = 'codex', args = {} },
    copilot = { protocol = 'acp', command = 'copilot', args = { '--acp', '--stdio' } },
    auggie = { protocol = 'acp', command = 'auggie', args = { '--acp' } },
    claude = { protocol = 'acp', command = 'claude-agent-acp', args = {} },
    cline = { protocol = 'acp', command = 'cline', args = { '--acp' } },
    cursor = { protocol = 'acp', command = 'cursor-agent', args = { 'acp' } },
    gemini = { protocol = 'acp', command = 'gemini', args = { '--acp' } },
    goose = { protocol = 'acp', command = 'goose', args = { 'acp' } },
    kimi = { protocol = 'acp', command = 'kimi', args = { 'acp' } },
    kiro = { protocol = 'acp', command = 'kiro-cli', args = { 'acp' } },
    opencode = { protocol = 'acp', command = 'opencode', args = { 'acp' } },
    qwen = { protocol = 'acp', command = 'qwen', args = { '--acp' } },
    vibe = { protocol = 'acp', command = 'vibe-acp', args = {} },
}

local defaults = {
    agent = 'codex',
    agents = {},
    commands = {},
    winbar = true,
    window = { position = 'right', width = 0.5, height = 0.5, float = {} },
    labels = { prompt = 'Prompt:', agent = 'Agent:' },
}

-- Current options; replaced as a whole by set().
M.options = vim.deepcopy(defaults)

-- Validators shared by several fields: vim.validate() validator, then message.
local function label(v)
    return type(v) == 'string' and v:find('%S') ~= nil
end
local non_empty = { label, 'non-empty string' }
local size = {
    function(v)
        return type(v) == 'number' and v > 0
    end,
    'positive number',
}
local strings = {
    function(v)
        return vim.islist(v)
            and #vim.tbl_filter(function(x)
                    return type(x) ~= 'string'
                end, v)
                == 0
    end,
    'list of strings',
}
local function one_of(set, msg)
    return {
        function(v)
            return set[v] ~= nil
        end,
        msg,
    }
end

-- Check a table of options: unknown keys are errors, every known key is optional.
-- fields: key -> a vim.validate() type spec, or { validator function, message }.
local function check(where, t, fields)
    vim.validate(where ~= '' and where or 'opts', t, 'table')
    local prefix = where ~= '' and (where .. '.') or ''
    for key in pairs(t) do
        if fields[key] == nil then
            error(('boomer: unknown option: %s%s'):format(prefix, tostring(key)), 0)
        end
    end
    for key, spec in pairs(fields) do
        local validator, msg = spec, nil
        if type(spec) == 'table' and type(spec[1]) == 'function' then
            validator, msg = spec[1], spec[2]
        end
        vim.validate(prefix .. key, t[key], validator, true, msg)
    end
end

local agent_fields = {
    protocol = one_of(M.protocols, '"codex" or "acp"'),
    command = 'string',
    args = strings,
    env = 'table',
    model = 'string',
    effort = 'string',
    mode = 'string',
    options = 'table',
    label = non_empty,
}

local function check_command(name, spec)
    local where = 'commands.' .. name
    if spec == false then
        return
    end
    check(where, spec, {
        desc = 'string',
        prompt = { 'string', 'function' },
        run = 'function',
        complete = { 'table', 'function' },
    })
    if (spec.prompt == nil) == (spec.run == nil) then
        error('boomer: ' .. where .. ' needs exactly one of `prompt` or `run`', 0)
    end
    if not name:match('^[%w_%-%.]+$') then
        error('boomer: invalid command name: ' .. name, 0)
    end
end

-- Built-ins overlaid with the user's profiles, field by field.
local function merge(agents)
    local out = vim.deepcopy(builtin)
    for name, p in pairs(agents) do
        out[name] = vim.tbl_extend('force', out[name] or {}, vim.deepcopy(p))
    end
    return out
end

-- Validate `opts` and make them the current options (see :help boomer-config).
-- Errors leave the previous options in place.
function M.set(opts)
    opts = opts or {}
    check('', opts, {
        agent = 'string',
        agents = 'table',
        commands = 'table',
        winbar = { 'boolean', 'function' },
        window = 'table',
        labels = 'table',
    })
    if opts.window then
        check('window', opts.window, {
            position = one_of(
                { left = 1, right = 1, top = 1, bottom = 1, float = 1 },
                '"left", "right", "top", "bottom" or "float"'
            ),
            width = size,
            height = size,
            float = 'table',
        })
    end
    if opts.labels then
        check('labels', opts.labels, { prompt = non_empty, agent = non_empty })
    end
    for name, p in pairs(opts.agents or {}) do
        check('agents.' .. tostring(name), p, agent_fields)
    end
    for name, spec in pairs(opts.commands or {}) do
        check_command(tostring(name), spec)
    end

    local agents = merge(opts.agents or {})
    for name, p in pairs(agents) do
        if not p.protocol or not p.command then
            error('boomer: agents.' .. name .. ' needs `protocol` and `command`', 0)
        end
    end
    local agent = opts.agent or defaults.agent
    if not agents[agent] then
        error('boomer: unknown agent: ' .. agent, 0)
    end

    local o = vim.tbl_deep_extend('force', vim.deepcopy(defaults), {
        window = opts.window,
        labels = opts.labels,
    })
    -- These replace the defaults as a whole rather than being merged into them
    -- (a float `border` list, for example).
    o.window.float = vim.deepcopy(opts.window and opts.window.float or {})
    o.commands = vim.deepcopy(opts.commands or {})
    if opts.winbar ~= nil then
        o.winbar = opts.winbar
    end
    o.agent, o.agents = agent, agents
    M.options = o
end

-- Sorted profile names.
---@return string[]
function M.agent_names()
    local names = vim.tbl_keys(M.options.agents)
    table.sort(names)
    return names
end

-- Sorted names of the profiles whose executable is installed, plus the
-- default agent and `keep` (the current one), offered by the agent picker.
---@param keep? string
---@return string[]
function M.installed_agent_names(keep)
    return vim.tbl_filter(function(name)
        return name == M.options.agent
            or name == keep
            or vim.fn.executable(M.options.agents[name].command) == 1
    end, M.agent_names())
end

-- A copy of the named profile (the default agent when nil), completed with
-- its name, Neovim's working directory and a label.
---@param name? string
---@return boomer.Profile?, string? err
function M.resolve(name)
    name = name or M.options.agent
    local p = M.options.agents[name]
    if not p then
        return nil, 'Unknown agent: ' .. tostring(name)
    end
    p = vim.deepcopy(p)
    p.name = name
    p.args, p.options = p.args or {}, p.options or {}
    p.cwd = vim.fs.normalize(vim.fn.getcwd())
    if vim.fn.has('win32') == 1 then
        -- Agents record and filter saved sessions by their own (native) cwd.
        p.cwd = p.cwd:gsub('/', '\\')
    end
    p.label = p.label or M.options.labels.agent
    return p
end

M.set({})

return M
