-- Codex App Server adapter (`codex app-server --listen stdio://`).
--
-- A chat session is a Codex thread; each prompt is a turn that ends with
-- turn/completed. Model, effort, collaboration mode and permission preset are
-- staged locally and sent with the next turn/start, which is how the Codex TUI
-- does it. Collaboration modes (plan mode) need the experimental API.
-- Implements the client interface described in boomer.init.
local adapter = require('boomer.adapter')
local util = require('boomer.util')
local M = {}

---@class boomer.Codex : boomer.Adapter
---@field models table[] model/list data, fetched at startup.
---@field model? string Staged by the user for the next turn.
---@field effort? string Staged by the user for the next turn.
---@field mode? string Staged collaboration mode ('default' or 'plan').
---@field permissions? string Staged permission preset value.
---@field current_model? string What the thread uses, as reported by the server.
---@field current_effort? string
---@field current_mode? string
---@field current_permissions? string Preset matching the thread's policies, or 'custom'.
---@field title? string
---@field limits? boomer.Limits Account rate limits, merged from reads and updates.
---@field turn? { cb: fun(err: table?, status: string?), id: string?, cancel: function?, interrupting: boolean? }
---@field changes table<string, table[]> Latest changes of the turn's fileChange items, by item ID.
---@field shown table<string, boolean> fileChange items whose diff was shown.
local Codex = adapter.class()

-- Start the app server, initialize it and fetch its models; cb(err) runs when
-- it is ready. Profile args follow the fixed server arguments.
---@param profile boomer.Profile
---@param on boomer.Callbacks
---@param cb fun(err: { message: string }?)
---@return boomer.Codex?, string?
function M.start(profile, on, cb)
    local cmd =
        vim.list_extend({ profile.command, 'app-server', '--listen', 'stdio://' }, profile.args)
    local self, err = adapter.spawn(Codex, { on = on, profile = profile, models = {} }, cmd)
    if not self then
        return nil, err
    end
    local rpc = self.rpc
    rpc:request('initialize', {
        clientInfo = { name = 'boomer', version = '0.1.0' },
        capabilities = { experimentalApi = true },
    }, function(e)
        if e then
            return cb(e)
        end
        rpc:notify('initialized')
        -- Without models the chat still works; /model has nothing to offer.
        rpc:request('model/list', { limit = 100 }, function(err, r)
            if err then
                on.error('model list: ' .. err.message)
            else
                self.models = r.data or {}
            end
            cb()
        end)
    end)
    return self
end

function Codex:reset_turn()
    self.changes, self.shown = {}, {}
end

-- Show the user and agent messages of a loaded thread's turns.
function Codex:replay(turns)
    for _, turn in ipairs(turns or {}) do
        for _, item in ipairs(turn.items or {}) do
            if item.type == 'userMessage' then
                local parts = {}
                for _, c in ipairs(item.content or {}) do
                    parts[#parts + 1] = c.type == 'text' and c.text
                        or ('[' .. tostring(c.type) .. ']')
                end
                self.on.text('user', table.concat(parts, '\n'), item.id)
            elseif item.type == 'agentMessage' and type(item.text) == 'string' then
                self.on.text('agent', item.text, item.id)
            end
        end
    end
end

-- Permission presets, as in the Codex TUI's /permissions.
local presets = {
    {
        value = 'read-only',
        label = 'Read Only',
        approval = 'on-request',
        sandbox = { type = 'readOnly' },
    },
    {
        value = 'auto',
        label = 'Default',
        approval = 'on-request',
        sandbox = { type = 'workspaceWrite' },
    },
    {
        value = 'full-access',
        label = 'Full Access',
        approval = 'never',
        sandbox = { type = 'dangerFullAccess' },
    },
}

-- Collaboration modes: the protocol's ModeKind values. collaborationMode/list
-- also suggests an effort per mode; the user's effort is kept instead.
local modes = {
    { value = 'default', label = 'Default' },
    { value = 'plan', label = 'Plan' },
}

local function find_preset(value)
    for _, p in ipairs(presets) do
        if p.value == value then
            return p
        end
    end
end

-- The preset matching a thread's policies; 'custom' for anything else.
local function current_preset(approval, sandbox)
    for _, p in ipairs(presets) do
        if
            approval == p.approval
            and type(sandbox) == 'table'
            and sandbox.type == p.sandbox.type
        then
            return p.value
        end
    end
    return (approval ~= nil or sandbox ~= nil) and 'custom' or nil
end

-- Report model, effort, title and permissions to the chat; a staged value
-- wins over the thread's current one. vim.NIL clears a field.
function Codex:report()
    local function opt(v)
        return v == nil and vim.NIL or v
    end
    local perm = self.permissions or self.current_permissions
    local preset = find_preset(perm)
    local mode = util.choice({ choices = modes }, self.mode or self.current_mode or '')
    self.on.status({
        model = opt(self.model or self.current_model),
        effort = opt(self.effort or self.current_effort),
        mode = opt(mode and mode.label),
        title = opt(self.title),
        permissions = opt(preset and preset.label or perm and 'Custom'),
    })
end

local function mode_kind(collab)
    return type(collab) == 'table' and type(collab.mode) == 'string' and collab.mode or nil
end

-- Shared by thread/start and thread/resume. A resumed thread's history comes
-- with the response, or, for paginated threads (whose embedded turns may be
-- partial), from thread/turns/list pages (capped at 100).
function Codex:open(method, params, cb)
    self.session, self.model, self.effort, self.title = params.threadId, nil, nil, nil
    self.mode, self.permissions, self.current_permissions = nil, nil, nil
    self.rpc:request(method, params, function(err, r)
        local thread = r and r.thread or {}
        if err or type(thread.id) ~= 'string' then
            self.session = nil
            cb(err or { message = 'missing thread ID' })
            return
        end
        self.session = thread.id
        self.current_model, self.current_effort = r.model, r.reasoningEffort
        self.current_mode = mode_kind(r.collaborationMode)
        self.current_permissions = current_preset(r.approvalPolicy, r.sandbox)
        self.title = type(thread.name) == 'string' and thread.name ~= '' and thread.name or nil
        self:report()
        if not params.threadId then
            cb()
        elseif thread.historyMode ~= 'paginated' then
            self:replay(thread.turns)
            cb()
        else
            local turns, pages = {}, 0
            local function page(cursor)
                self.rpc:request('thread/turns/list', {
                    threadId = thread.id,
                    cursor = cursor,
                    itemsView = 'full',
                    sortDirection = 'asc',
                }, function(e, res)
                    if e then
                        cb(e)
                        return
                    end
                    vim.list_extend(turns, res.data or {})
                    pages = pages + 1
                    if type(res.nextCursor) == 'string' and pages < 100 then
                        page(res.nextCursor)
                    else
                        self:replay(turns)
                        cb()
                    end
                end)
            end
            page()
        end
    end)
end

-- Visible models from model/list, as choices.
local function model_choices(models)
    local out = {}
    for _, m in ipairs(models or {}) do
        if not m.hidden then
            local id = m.model or m.id
            out[#out + 1] = { label = m.displayName or id, value = id }
        end
    end
    return out
end

-- Efforts supported by `model`, or by the server's default model when nil.
local function effort_choices(models, model)
    for _, m in ipairs(models or {}) do
        local id = m.model or m.id
        if id == model or not model and m.isDefault then
            return vim.tbl_map(function(e)
                return { label = e.reasoningEffort, value = e.reasoningEffort }
            end, m.supportedReasoningEfforts or {})
        end
    end
    return {}
end

-- Profile defaults are matched by ID or name. The model goes to
-- thread/start, the effort and mode are staged for the first turn; a value
-- that is not offered is reported and skipped.
function Codex:new_session(cwd, cb)
    local p = self.profile
    local function resolve(key, choices)
        if not p[key] then
            return nil
        end
        local choice = util.choice({ choices = choices }, p[key])
        if not choice then
            self.on.error(('default %s: %s is not offered by this agent'):format(key, p[key]))
        end
        return choice and choice.value
    end
    local model = resolve('model', model_choices(self.models))
    local effort = resolve('effort', effort_choices(self.models, model))
    local mode = resolve('mode', modes)
    self:open('thread/start', { cwd = cwd, model = model }, function(err)
        if not err and (effort or mode) then
            self.effort, self.mode = effort, mode
            self:report()
        end
        cb(err)
    end)
end

function Codex:load_session(id, cwd, cb)
    self:open('thread/resume', { cwd = cwd, threadId = id }, cb)
end

-- Saved threads for cwd (first page only, newest first).
function Codex:list_sessions(cwd, cb)
    self.rpc:request('thread/list', {
        cwd = cwd,
        archived = false,
        sortKey = 'updated_at',
        sortDirection = 'desc',
    }, function(err, r)
        if err then
            cb(err)
            return
        end
        local items = {}
        for _, t in ipairs(r.data or {}) do
            if type(t) == 'table' and type(t.id) == 'string' then
                local title = t.name ~= '' and t.name or t.preview or t.id
                items[#items + 1] = {
                    id = t.id,
                    title = tostring(title),
                    updated = type(t.updatedAt) == 'number'
                            and os.date('%Y-%m-%d %H:%M', t.updatedAt)
                        or nil,
                }
            end
        end
        cb(nil, items)
    end)
end

-- Start a turn with the staged settings. cb(err, status) runs once when
-- turn/completed arrives (or the agent exits). A chosen permission preset
-- applies to this turn and later ones.
function Codex:prompt(text, cb)
    local preset = find_preset(self.permissions)
    -- The mode's settings override the turn's model and effort, so they carry
    -- the same ones; Codex requires the model. After a model change, the
    -- thread's effort is kept only if the new model offers it.
    local model = self.model or self.current_model
    local effort = self.effort or self.current_effort
    if effort and not self.effort and model ~= self.current_model then
        local offered = util.choice({ choices = effort_choices(self.models, model) }, effort)
        effort = offered and effort or nil
    end
    local collab = self.mode
        and model
        and {
            mode = self.mode,
            settings = {
                model = model,
                reasoning_effort = effort or vim.NIL,
                -- null: the mode's built-in instructions.
                developer_instructions = vim.NIL,
            },
        }
    local turn = { cb = cb }
    self.turn = turn
    self.rpc:request('turn/start', {
        threadId = self.session,
        input = { { type = 'text', text = text, text_elements = {} } },
        model = self.model,
        effort = self.effort,
        collaborationMode = collab or nil,
        approvalPolicy = preset and preset.approval,
        sandboxPolicy = preset and preset.sandbox,
    }, function(err, r)
        if self.turn == turn then
            if err then
                self:finish(err)
            else
                self:started(r.turn and r.turn.id)
            end
        end
    end, false)
end

-- Native compaction, which runs as a turn: its ID arrives with turn/started.
function Codex:compact(cb)
    local turn = { cb = cb }
    self.turn = turn
    self.rpc:request('thread/compact/start', { threadId = self.session }, function(err)
        if err and self.turn == turn then
            self:finish(err)
        end
    end)
end

-- The turn ID comes from the turn/start response or turn/started, whichever
-- is first. turn/interrupt needs it, so a cancel requested earlier waits here.
function Codex:started(id)
    local turn = self.turn
    if turn and type(id) == 'string' and not turn.id then
        turn.id = id
        if turn.cancel then
            self:cancel(turn.cancel)
        end
    end
end

-- Interrupt the turn; it ends with turn/completed (status "interrupted").
-- cb(err) runs only if the interrupt fails while the turn is still running.
function Codex:cancel(cb)
    local turn = self.turn
    if not turn then
        return
    end
    turn.cancel = cb or function() end
    self:settle_requests()
    if turn.id and not turn.interrupting then
        turn.interrupting = true
        self.rpc:request(
            'turn/interrupt',
            { threadId = self.session, turnId = turn.id },
            function(err)
                turn.interrupting = false
                if err and self.turn == turn then
                    local done = turn.cancel
                    turn.cancel = nil
                    done(err)
                end
            end
        )
    end
end

-- Thread items shown as tool lines, and the field that titles them.
local tools = {
    commandExecution = 'command',
    fileChange = 'changes',
    mcpToolCall = 'tool',
    dynamicToolCall = 'tool',
    collabAgentToolCall = 'tool',
    webSearch = 'query',
    imageView = 'path',
}

local function tool_title(item)
    local field = tools[item.type]
    if not field then
        return nil
    end
    local value = item[field]
    if item.type == 'fileChange' and type(value) == 'table' then
        local paths = {}
        for _, change in ipairs(value) do
            paths[#paths + 1] = change.path
        end
        value = 'edit ' .. table.concat(paths, ', ')
    end
    return type(value) == 'string' and value or item.type
end

-- A fileChange item's changes as diffs. Codex sends the whole text of added
-- and deleted files, and hunks for updates, followed by a "Moved to:" note
-- for moves.
---@return boomer.Diff[]
local function file_diffs(changes)
    local out = {}
    for _, change in ipairs(type(changes) == 'table' and changes or {}) do
        local kind = type(change.kind) == 'table' and change.kind or {}
        local text = type(change.diff) == 'string' and change.diff or ''
        local path = tostring(change.path or '?')
        if kind.type == 'add' then
            out[#out + 1] = { to = path, text = util.hunks('', text) }
        elseif kind.type == 'delete' then
            out[#out + 1] = { from = path, text = util.hunks(text, '') }
        else
            local to = type(kind.move_path) == 'string' and kind.move_path or path
            text = text:gsub('\n*Moved to: [^\n]*\n?$', '')
            text = text:gsub('^%-%-%- [^\n]*\n%+%+%+ [^\n]*\n', '')
            out[#out + 1] = { from = path, to = to, text = text }
        end
    end
    return out
end

-- The diffs of file change item `id`, unless already shown; they count as
-- shown from now on.
---@return boomer.Diff[]?
function Codex:take_diffs(id)
    if id == nil or self.shown[id] then
        return nil
    end
    local list = util.shown(file_diffs(self.changes[id]))
    self.shown[id] = list ~= nil or nil
    return list
end

-- Merge a rate-limit snapshot into the known windows and report them. Updates
-- may be sparse and may describe other buckets (per-model limits), which are
-- skipped: the `codex` bucket holds the 5-hour and weekly limits.
function Codex:merge_limits(snap)
    if type(snap) ~= 'table' or (snap.limitId and snap.limitId ~= 'codex') then
        return
    end
    local limits = vim.deepcopy(self.limits or {})
    for _, key in ipairs({ 'primary', 'secondary' }) do
        local w = snap[key]
        if type(w) == 'table' and type(w.usedPercent) == 'number' then
            limits[key] = {
                used = w.usedPercent,
                window = w.windowDurationMins or (limits[key] or {}).window,
                resets = w.resetsAt or (limits[key] or {}).resets,
            }
        end
    end
    if next(limits) then
        self.limits = limits
        self.on.status({ limits = vim.deepcopy(limits) })
    end
end

-- Refresh the account's rate limits; cb() runs once they are known or the
-- read failed (API-key logins have none), keeping what updates reported.
function Codex:rate_limits(cb)
    self.rpc:request('account/rateLimits/read', nil, function(err, r)
        if not err and type(r) == 'table' then
            self:merge_limits(r.rateLimits)
        end
        cb()
    end, 10000)
end

function Codex:notification(method, p)
    if method == 'account/rateLimits/updated' then
        self:merge_limits(p.rateLimits)
        return
    elseif method == 'serverRequest/resolved' then
        -- The server withdrew an approval request (the turn moved on).
        local req = self.requests[p.requestId]
        if req then
            req.done = true
            self.requests[p.requestId] = nil
            self.on.settled()
        end
        return
    elseif p.threadId ~= self.session then
        return
    end
    if method == 'item/agentMessage/delta' then
        self.on.text('agent', p.delta or '', p.itemId)
    elseif method == 'turn/started' then
        self:started(p.turn and p.turn.id)
    elseif method == 'turn/completed' then
        local turn = p.turn or {}
        if self.turn and (not self.turn.id or self.turn.id == turn.id) then
            if turn.status == 'failed' then
                self:finish({ message = turn.error and turn.error.message or 'turn failed' })
            else
                self:finish(nil, turn.status == 'interrupted' and 'cancelled' or turn.status)
            end
        end
    elseif method == 'thread/tokenUsage/updated' then
        local u = type(p.tokenUsage) == 'table' and p.tokenUsage or {}
        local total, last = u.total or {}, u.last or {}
        self.on.status({
            tokens = {
                total = total.totalTokens,
                input = total.inputTokens,
                output = total.outputTokens,
            },
            -- The last request's size is what currently fills the context window.
            context = { used = last.totalTokens, size = u.modelContextWindow },
        })
    elseif method == 'thread/settings/updated' then
        local s = type(p.threadSettings) == 'table' and p.threadSettings or {}
        self.current_model, self.current_effort = s.model, s.effort
        self.current_mode = mode_kind(s.collaborationMode)
        self:report()
    elseif method == 'thread/name/updated' then
        self.title = p.threadName
        self:report()
    elseif method == 'item/fileChange/patchUpdated' then
        -- Patches stream in while the model writes them: keep the latest,
        -- shown once complete (item/started or the approval request).
        if p.itemId ~= nil then
            self.changes[p.itemId] = p.changes
        end
    elseif method == 'item/started' or method == 'item/completed' then
        local item = p.item or {}
        local title = tool_title(item)
        if title and method == 'item/started' then
            self.on.tool(title)
        elseif title and (item.status == 'failed' or item.status == 'declined') then
            self.on.tool(title .. ' | ' .. item.status)
        end
        if item.type == 'fileChange' and item.id ~= nil then
            if type(item.changes) == 'table' and #item.changes > 0 then
                self.changes[item.id] = item.changes
            end
            local diffs = self:take_diffs(item.id)
            if diffs then
                self.on.diff(diffs)
            end
        end
    end
end

-- Answer outstanding approvals with their deny result (before a cancel, or
-- after the turn ended).
function Codex:settle_requests()
    for _, req in pairs(self.requests) do
        req.reply(req.deny)
    end
end

local labels = {
    accept = 'Allow once',
    acceptForSession = 'Allow for this session',
    cancel = 'Deny and stop the turn',
}

-- Translate an approval request into a boomer.Permission (without `reply`),
-- or nil for an unknown method. "decline" is the Deny entry, so it is not
-- repeated among the choices; structured policy amendments are passed through.
local function approval(method, p)
    local details = {}
    for _, key in ipairs({ 'command', 'cwd', 'reason', 'grantRoot', 'permissions' }) do
        if p[key] ~= nil then
            local v = p[key]
            details[#details + 1] = key .. ': ' .. (type(v) == 'string' and v or vim.json.encode(v))
        end
    end
    if method == 'item/permissions/requestApproval' then
        return {
            title = 'Grant permissions',
            details = details,
            choices = {
                {
                    label = 'Grant for this turn',
                    result = { permissions = p.permissions or vim.empty_dict(), scope = 'turn' },
                },
            },
            deny = { permissions = vim.empty_dict(), scope = 'turn' },
        }
    end
    local commands = method == 'item/commandExecution/requestApproval'
    if not commands and method ~= 'item/fileChange/requestApproval' then
        return nil
    end
    -- Servers that do not list the decisions accept these.
    local decisions = type(p.availableDecisions) == 'table' and p.availableDecisions
        or { 'accept', 'acceptForSession', 'decline', 'cancel' }
    local choices = {}
    for _, d in ipairs(decisions) do
        if d ~= 'decline' then
            choices[#choices + 1] = {
                label = labels[d] or ('Policy change: ' .. vim.json.encode(d)),
                result = { decision = d },
            }
        end
    end
    return {
        title = commands and 'Run command' or 'Apply file changes',
        details = details,
        choices = choices,
        deny = { decision = 'decline' },
    }
end

-- Approval requests outside the current turn are denied without asking.
function Codex:server_request(method, p, reply, id)
    local req = approval(method, p)
    if not req then
        reply({ code = -32601, message = 'Method not supported: ' .. method })
        return
    end
    if p.threadId ~= self.session or not self.turn then
        reply(nil, req.deny)
        return
    end
    if method == 'item/fileChange/requestApproval' then
        req.diffs = self:take_diffs(p.itemId)
    end
    self:ask(id, req, reply)
end

-- Model, effort, mode and permissions.
---@return boomer.Setting[]
function Codex:settings()
    local model = self.model or self.current_model
    return {
        {
            id = 'model',
            label = 'Model',
            category = 'model',
            current = model,
            choices = model_choices(self.models),
        },
        {
            id = 'effort',
            label = 'Reasoning effort',
            category = 'thought_level',
            current = self.effort or self.current_effort,
            choices = effort_choices(self.models, model),
        },
        {
            id = 'mode',
            label = 'Mode',
            category = 'mode',
            current = self.mode or self.current_mode,
            choices = vim.deepcopy(modes),
        },
        {
            id = 'permissions',
            label = 'Permissions',
            category = 'permissions',
            current = self.permissions or self.current_permissions,
            choices = vim.tbl_map(function(p)
                return { label = p.label, value = p.value }
            end, presets),
        },
    }
end

-- Stage a setting for the next turn. A new model may not support the
-- previous effort, so the effort is reset.
function Codex:configure(id, value, cb)
    if id == 'model' then
        self.model, self.effort = value, nil
    elseif id == 'permissions' then
        self.permissions = value
    elseif id == 'mode' then
        self.mode = value
    else
        self.effort = value
    end
    self:report()
    cb()
end

return M
