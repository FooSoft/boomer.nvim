-- ACP v1 adapter (Agent Client Protocol: GitHub Copilot via `copilot --acp
-- --stdio`, Gemini CLI, Claude Agent and the other built-in ACP profiles).
--
-- A prompt is one long-lived session/prompt request; session/update
-- notifications stream text, tool calls and status meanwhile. Settings are the
-- agent's session config options (plus legacy session modes and models),
-- changed on the agent immediately. Implements the client interface described
-- in boomer.init.
local Rpc = require('boomer.rpc')
local util = require('boomer.util')
local M = {}

---@class boomer.Acp : boomer.Client
---@field rpc boomer.Rpc
---@field on boomer.Callbacks
---@field profile boomer.Profile
---@field caps table agentCapabilities from initialize.
---@field options? table[] The session's configOptions, as last reported.
---@field modes? table Legacy session modes: { currentModeId, availableModes }.
---@field models? table Legacy session models: { currentModelId, availableModels }.
---@field title? string
---@field loading? boolean A session/load is replaying history.
---@field early? table[] session/update params that arrived before session/new returned.
---@field turn? { cb: fun(err: table?, status: string?) }
---@field requests table<any, boomer.Permission> Open permission requests by RPC ID.
---@field tools table<string, string> Tool call titles by ID, for failure lines.
local Acp = {}
Acp.__index = Acp

local cancelled = { outcome = { outcome = 'cancelled' } }

-- Start the agent and initialize it; cb(err) runs when it is ready. The
-- profile's args are the whole argument list.
---@param profile boomer.Profile
---@param on boomer.Callbacks
---@param cb fun(err: { message: string }?)
---@return boomer.Acp?, string?
function M.start(profile, on, cb)
    local self = setmetatable({ on = on, requests = {}, tools = {}, profile = profile }, Acp)
    local rpc, err = Rpc.start({
        cmd = vim.list_extend({ profile.command }, vim.deepcopy(profile.args or {})),
        cwd = profile.cwd,
        env = profile.env,
        jsonrpc = true,
        notify = function(method, params)
            if method ~= 'session/update' then
                return
            elseif params.sessionId == self.session then
                self:update(params.update or {})
            elseif self.early then
                -- Agents may announce a new session (such as its commands)
                -- before session/new returns its ID; open() replays these.
                self.early[#self.early + 1] = params
            end
        end,
        request = function(method, params, reply, id)
            self:server_request(method, params, reply, id)
        end,
        log = on.error,
        exit = function(msg)
            on.exit(msg)
            self:finish({ message = msg })
        end,
    })
    if not rpc then
        return nil, err
    end
    self.rpc = rpc
    rpc:request('initialize', {
        protocolVersion = 1,
        clientCapabilities = vim.empty_dict(),
        clientInfo = { name = 'boomer', version = '0.1.0' },
    }, function(e, r)
        if not e and r.protocolVersion ~= 1 then
            e = { message = 'unsupported ACP version ' .. tostring(r.protocolVersion) }
        end
        self.caps = not e and r.agentCapabilities or {}
        cb(e)
    end)
    return self
end

function Acp:close(force)
    self.rpc:close(force)
end

-- Shared by session/new and session/load. A loaded session's history arrives
-- as session/update notifications before session/load returns.
function Acp:open(method, params, cb)
    self.session, self.options, self.modes, self.models = params.sessionId, nil, nil, nil
    self.title = nil
    self.loading = method == 'session/load'
    self.early = not params.sessionId and {} or nil
    self.rpc:request(method, params, function(err, r)
        self.loading = false
        local early = self.early or {}
        self.early = nil
        local id = r and r.sessionId or params.sessionId
        if err or type(id) ~= 'string' then
            self.session = nil
            cb(err or { message = 'missing session ID' })
            return
        end
        self.session, self.options = id, r.configOptions
        self.modes = type(r.modes) == 'table' and r.modes or nil
        self.models = type(r.models) == 'table' and r.models or nil
        self:report()
        for _, p in ipairs(early) do
            if p.sessionId == id then
                self:update(p.update or {})
            end
        end
        cb()
    end)
end

-- Profile defaults (model, effort, mode and raw `options`) apply to new
-- sessions only, one after another. A refused default is reported and the
-- session stays usable.
function Acp:new_session(cwd, cb)
    self:open('session/new', { cwd = cwd, mcpServers = {} }, function(err)
        if err then
            return cb(err)
        end
        local todo = {}
        local list = self:setting_list()
        for key, category in pairs(util.categories) do
            local value = self.profile[key]
            if value then
                local setting = util.find(list, category)
                local choice = setting and util.choice(setting, value)
                if choice then
                    todo[#todo + 1] = { id = setting.id, value = choice.value }
                else
                    self.on.error(
                        ('default %s: %s is not offered by this agent'):format(key, value)
                    )
                end
            end
        end
        for id, value in pairs(self.profile.options or {}) do
            todo[#todo + 1] = { id = id, value = value }
        end
        -- A stable order keeps the requests predictable.
        table.sort(todo, function(a, b)
            return a.id < b.id
        end)
        local function step(i)
            local t = todo[i]
            if not t then
                return cb()
            end
            self:configure(t.id, t.value, function(e)
                if e then
                    self.on.error('default ' .. t.id .. ': ' .. e.message)
                end
                step(i + 1)
            end)
        end
        step(1)
    end)
end

function Acp:load_session(id, cwd, cb)
    if not self.caps.loadSession then
        cb({ message = 'this agent cannot load sessions' })
        return
    end
    self:open('session/load', { cwd = cwd, mcpServers = {}, sessionId = id }, cb)
end

-- Saved sessions for cwd (first page only).
function Acp:list_sessions(cwd, cb)
    if type((self.caps.sessionCapabilities or {}).list) ~= 'table' then
        cb({ message = 'this agent cannot list sessions' })
        return
    end
    self.rpc:request('session/list', { cwd = cwd }, function(err, r)
        if err then
            cb(err)
            return
        end
        local items = {}
        for _, s in ipairs(r.sessions or {}) do
            if type(s) == 'table' and type(s.sessionId) == 'string' then
                items[#items + 1] = {
                    id = s.sessionId,
                    title = tostring(s.title or s.sessionId),
                    -- ISO 8601 shortened to "YYYY-MM-DD HH:MM".
                    updated = type(s.updatedAt) == 'string' and s.updatedAt
                        :sub(1, 16)
                        :gsub('T', ' ') or nil,
                }
            end
        end
        cb(nil, items)
    end)
end

-- Text of a content block; other kinds (images, resources) show as "[type]".
local function content_text(content)
    if type(content) ~= 'table' then
        return ''
    end
    return content.type == 'text' and tostring(content.text or '')
        or ('[' .. tostring(content.type) .. ']')
end

-- Handle one session/update for the current session.
function Acp:update(u)
    local kind = u.sessionUpdate
    if kind == 'usage_update' then
        local cost = type(u.cost) == 'table' and u.cost or nil
        self.on.status({
            context = { used = u.used, size = u.size },
            cost = cost and { amount = cost.amount, currency = cost.currency } or nil,
        })
    elseif kind == 'available_commands_update' then
        local list = {}
        for _, c in ipairs(u.availableCommands or {}) do
            if type(c) == 'table' and type(c.name) == 'string' then
                local input = type(c.input) == 'table' and c.input or {}
                list[#list + 1] = {
                    name = c.name,
                    desc = type(c.description) == 'string' and c.description or nil,
                    hint = type(input.hint) == 'string' and input.hint or nil,
                }
            end
        end
        self.on.commands(list)
    elseif kind == 'session_info_update' then
        if type(u.title) == 'string' then
            self.title = u.title
            self:report()
        end
    elseif kind == 'current_mode_update' then
        if self.modes then
            self.modes.currentModeId = u.currentModeId
            self:report()
        end
    elseif kind == 'config_option_update' then
        self.options = u.configOptions
        self:report()
    elseif kind == 'agent_message_chunk' then
        self.on.text('agent', content_text(u.content), u.messageId)
    elseif kind == 'user_message_chunk' and self.loading then
        -- Only replayed history: live user chunks echo what the prompt buffer
        -- already shows.
        self.on.text('user', content_text(u.content), u.messageId)
    elseif self.loading then
        -- Replayed history shows messages only.
        return
    elseif kind == 'tool_call' then
        local title = tostring(u.title or u.kind or 'tool')
        self.tools[u.toolCallId or title] = title
        self.on.tool(title)
    elseif kind == 'tool_call_update' and u.status == 'failed' then
        self.on.tool(tostring(u.title or self.tools[u.toolCallId] or 'tool') .. ' | failed')
    end
end

-- Send a prompt. cb(err, status) runs once when session/prompt returns (or
-- the agent exits); status is 'completed' or the agent's stop reason.
function Acp:prompt(text, cb)
    local turn = { cb = cb }
    self.turn = turn
    self.rpc:request(
        'session/prompt',
        { sessionId = self.session, prompt = { { type = 'text', text = text } } },
        function(err, r)
            if self.turn ~= turn then
                return
            end
            local usage = r and type(r.usage) == 'table' and r.usage
            if usage then
                self.on.status({
                    tokens = {
                        total = usage.totalTokens,
                        input = usage.inputTokens,
                        output = usage.outputTokens,
                    },
                })
            end
            local reason = r and r.stopReason
            self:finish(err, (reason == nil or reason == 'end_turn') and 'completed' or reason)
        end,
        false
    )
end

-- The spec requires pending permission requests to be answered as cancelled.
-- session/cancel is a notification, so there is no failure to report; the
-- turn ends when session/prompt returns with stopReason "cancelled".
function Acp:cancel()
    if self.turn then
        self:settle_requests()
        self.rpc:notify('session/cancel', { sessionId = self.session })
    end
end

function Acp:finish(err, status)
    local turn = self.turn
    if turn then
        self.turn = nil
        self.tools = {}
        self:settle_requests()
        turn.cb(err, status)
    end
end

function Acp:settle_requests()
    for _, req in pairs(self.requests) do
        req.reply(cancelled)
    end
end

-- session/request_permission is the only request agents send us (we advertise
-- no file system or terminal capabilities). The agent's reject-once option
-- becomes "Deny"; without one, Deny answers cancelled.
function Acp:server_request(method, p, reply, id)
    if method ~= 'session/request_permission' then
        reply({ code = -32601, message = 'Method not supported: ' .. method })
        return
    end
    if p.sessionId ~= self.session or not self.turn then
        reply(nil, cancelled)
        return
    end
    local tool = type(p.toolCall) == 'table' and p.toolCall or {}
    local req = { title = tostring(tool.title or 'Tool call'), details = {}, choices = {} }
    if tool.kind then
        req.details[1] = 'kind: ' .. tostring(tool.kind)
    end
    for _, o in ipairs(p.options or {}) do
        local result = { outcome = { outcome = 'selected', optionId = o.optionId } }
        if o.kind == 'reject_once' and not req.deny then
            req.deny = result
        else
            req.choices[#req.choices + 1] =
                { label = tostring(o.name or o.optionId), result = result }
        end
    end
    req.deny = req.deny or cancelled
    req.reply = function(result)
        if not req.done then
            req.done = true
            self.requests[id] = nil
            reply(nil, result)
        end
    end
    self.requests[id] = req
    self.on.permission(req)
end

-- Select options may be grouped; flatten them to "Group / Name" labels.
local function flatten(options, prefix, out)
    for _, o in ipairs(options or {}) do
        if o.options then
            flatten(o.options, prefix .. tostring(o.name or '') .. ' / ', out)
        else
            out[#out + 1] = { label = prefix .. tostring(o.name or o.value), value = o.value }
        end
    end
    return out
end

-- Legacy session modes and models (from the session/new result), as `$mode`
-- and `$model` settings. `item` is the ID key of a list entry, `param` that
-- of the request changing it.
local legacy = {
    {
        id = '$mode',
        label = 'Mode',
        category = 'mode',
        field = 'modes',
        current = 'currentModeId',
        list = 'availableModes',
        item = 'id',
        method = 'session/set_mode',
        param = 'modeId',
    },
    {
        id = '$model',
        label = 'Model',
        category = 'model',
        field = 'models',
        current = 'currentModelId',
        list = 'availableModels',
        item = 'modelId',
        method = 'session/set_model',
        param = 'modelId',
    },
}

-- The session's settings. Legacy session modes and models appear when no
-- config option has their category.
---@return boomer.Setting[]
function Acp:setting_list()
    local list = {}
    for _, o in ipairs(self.options or {}) do
        local choices = o.type == 'boolean'
                and { { label = 'true', value = true }, { label = 'false', value = false } }
            or flatten(o.options, '', {})
        if #choices > 0 then
            list[#list + 1] = {
                id = o.id,
                label = o.name or o.id,
                category = o.category,
                current = o.currentValue,
                choices = choices,
            }
        end
    end
    for _, l in ipairs(legacy) do
        local state = self[l.field]
        if state and not util.find(list, l.category) and type(state[l.list]) == 'table' then
            local choices = {}
            for _, m in ipairs(state[l.list]) do
                if type(m) == 'table' and m[l.item] ~= nil then
                    choices[#choices + 1] =
                        { label = tostring(m.name or m[l.item]), value = m[l.item] }
                end
            end
            if #choices > 0 then
                list[#list + 1] = {
                    id = l.id,
                    label = l.label,
                    category = l.category,
                    current = state[l.current],
                    choices = choices,
                }
            end
        end
    end
    return list
end

-- Everything is known locally; answers immediately.
function Acp:settings(cb)
    cb(nil, self:setting_list())
end

-- Report title, model, effort and mode labels to the chat.
function Acp:report()
    local fields = { title = self.title or vim.NIL }
    local list = self:setting_list()
    for key, category in pairs(util.categories) do
        local setting = util.find(list, category)
        fields[key] = setting and util.current_label(setting) or vim.NIL
    end
    self.on.status(fields)
end

-- Change a setting on the agent; cb(err) when it answered.
function Acp:configure(id, value, cb)
    for _, l in ipairs(legacy) do
        if id == l.id then
            self.rpc:request(
                l.method,
                { sessionId = self.session, [l.param] = value },
                function(err)
                    local state = self[l.field]
                    if not err and state then
                        state[l.current] = value
                        self:report()
                    end
                    cb(err)
                end
            )
            return
        end
    end
    self.rpc:request(
        'session/set_config_option',
        { sessionId = self.session, configId = id, value = value },
        function(err, r)
            if not err and r.configOptions then
                self.options = r.configOptions
                self:report()
            end
            cb(err)
        end
    )
end

return M
