-- The chat: one at a time, made of an agent client (boomer.codex or
-- boomer.acp), its current session, and the prompt buffer showing it
-- (boomer.view). Switching sessions keeps the client and swaps in a fresh
-- buffer; switching agents replaces both.
--
-- Data flow: the prompt callback and :Boomer commands call into this module,
-- which drives the client; the client talks JSON-RPC to the agent
-- (boomer.rpc) and reports back through the `on` callbacks set up in start().
-- All callbacks run on the main loop, so no locking is needed.

---Callbacks an adapter reports through.
---@class boomer.Callbacks
---@field text fun(role: 'user'|'agent', text: string, id: string?) Message text (streamed).
---@field tool fun(title: string) A tool call started (or failed).
---@field error fun(msg: string)
---@field permission fun(req: boomer.Permission) The agent asks before acting.
---@field exit fun(msg: string) The agent process exited.
---@field status fun(fields: table) Status fields to merge; vim.NIL clears one.
---@field commands fun(list: { name: string, desc: string?, hint: string? }[]) Agent slash commands.

---A permission request. Answered at most once: by the user, or by the
---adapter (cancel, turn end), which sets `done`.
---@class boomer.Permission
---@field title string
---@field details string[]
---@field choices { label: string, result: any }[] Everything but Deny.
---@field deny any Result sent for Deny (and when the picker is dismissed).
---@field reply fun(result: any)
---@field done? boolean

---The adapter interface, implemented by boomer.codex and boomer.acp. Errors
---are { message = string } tables; `session` is set while a session is open.
---@class boomer.Client
---@field session? string
---@field close fun(self, force: boolean?)
---@field new_session fun(self, cwd: string, cb: fun(err: table?))
---@field load_session fun(self, id: string, cwd: string, cb: fun(err: table?))
---@field list_sessions fun(self, cwd: string, cb: fun(err: table?, items: { id: string, title: string, updated: string? }[]?))
---@field prompt fun(self, text: string, cb: fun(err: table?, status: string?))
---@field cancel fun(self, cb: fun(err: table)?)
---@field compact? fun(self, cb: fun(err: table?, status: string?)) Native compaction, if supported.
---@field setting_list fun(self): boomer.Setting[] What is known without asking the agent.
---@field settings fun(self, cb: fun(err: table?, list: boomer.Setting[]?)) May ask the agent.
---@field configure fun(self, id: string, value: any, cb: fun(err: table?))

local config = require('boomer.config')
local util = require('boomer.util')
local commands = require('boomer.commands')
local status_mod = require('boomer.status')
local M = {}

---@class boomer.Chat
---@field opts boomer.Profile
---@field client? boomer.Client nil if the agent failed to start.
---@field view table boomer.view instance showing the current session.
---@field state boomer.Status
---@field session? string Open session ID (set once it is ready).
---@field agent_commands table<string, table> Slash commands advertised by the agent.
---@field sessions? table[] Last listed saved sessions (for completion).
---@field queue boomer.Permission[] Permission requests waiting to be shown.
---@field prompts boomer.Queued[] Prompts waiting for the turn or session to be ready.
---@field asking? boomer.Permission The request being shown.
---@field loading? boolean Starting the agent or opening a session.
---@field busy? boolean A turn is running.
---@field cancelling? boolean
---@field dead? boolean The agent exited or failed to start.
---@field closed? boolean Closed by the user; callbacks are ignored.
---@field picks? integer Picker generation; see pick().
---@field progress? integer ID of the running progress message.

---A queued prompt.
---@class boomer.Queued
---@field text string Sent to the agent.
---@field line string As typed; shown when sent, or put back into the draft.
---@field shown? boolean Already in the transcript (committed by the prompt buffer).

---@type boomer.Chat?
local chat
local group = vim.api.nvim_create_augroup('Boomer', { clear = true })

-- Validate and apply options; see :help boomer-config.
---@param opts? table
function M.setup(opts)
    config.set(opts)
end

-- Warn and return nil, so command functions can `return warn(...)`.
local function warn(msg)
    vim.notify(msg, vim.log.levels.WARN, { title = 'Boomer' })
    return nil
end

-- Merge status fields (vim.NIL clears one) and announce the change.
local function update(c, fields)
    for k, v in pairs(fields) do
        if v == vim.NIL then
            c.state[k] = nil
        else
            c.state[k] = v
        end
    end
    status_mod.changed(c)
end

local function status(c, s)
    update(c, { state = s })
end

-- A progress message (:help progress-message) for the running turn, updated
-- in place by its ID. Older UIs without it are skipped.
local function progress(c, state, msg)
    local ok, id = pcall(vim.api.nvim_echo, { { msg } }, false, {
        id = c.progress,
        kind = 'progress',
        source = 'boomer',
        title = 'Boomer',
        status = state,
    })
    c.progress = ok and state == 'running' and id or nil
end

-- Write an error into the chat. After the agent exits, later errors only
-- repeat the exit message, so they are dropped.
local function report(c, msg)
    if not c.dead then
        c.view:write('Error: ' .. msg:gsub('%s+$', ''), 'BoomerError')
    end
end

-- Prompt queue ------------------------------------------------------------------
--
-- Prompts submitted while a turn runs or the session loads wait in c.prompts
-- and are sent one per turn, in order (drain). They are shown as virtual
-- lines until sent. A cancel, a failed turn or the loss of the session puts
-- them back into the draft (restore).

local function sync_queue(c)
    c.view:set_queued(vim.tbl_map(function(e)
        return e.line
    end, c.prompts))
    update(c, { queued = #c.prompts > 0 and #c.prompts or vim.NIL })
end

-- Move the queued prompts into the draft, before what is being typed.
local function restore(c)
    if #c.prompts == 0 then
        return
    end
    local parts = vim.tbl_map(function(e)
        return e.line
    end, c.prompts)
    c.prompts = {}
    sync_queue(c)
    if c.view:valid() then
        local current = c.view:draft()
        if current ~= '' then
            parts[#parts + 1] = current
        end
        c.view:set_draft(table.concat(parts, '\n\n'))
    end
end

local function fail(c, msg)
    report(c, msg)
    c.dead, c.loading = true, false
    status(c, 'failed')
    restore(c)
    if c.client then
        c.client:close()
    end
end

local function close(c)
    if chat == c then
        chat = nil
    end
    c.closed, c.queue, c.prompts = true, {}, {}
    if c.client then
        c.client:close()
    end
    if c.busy then
        progress(c, 'failed', 'closed')
    end
end

-- Pickers --------------------------------------------------------------------
--
-- vim.ui.select pickers leave Insert mode. A picker opened from Insert mode in
-- the chat (typing /model) returns there once it, and any picker its answer
-- opens, is done, so the user can keep typing.

-- Start Insert mode at the end of the draft if `win` is the current chat window.
local function insert(win)
    if win ~= vim.api.nvim_get_current_win() or vim.bo.filetype ~= 'boomer' then
        return
    end
    local last = vim.api.nvim_buf_line_count(0)
    local line = vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1]
    vim.api.nvim_win_set_cursor(0, { last, #line })
    vim.cmd.startinsert({ bang = true })
end

-- Insert mode in `win` after a picker, once Normal mode is back: some pickers
-- answer before leaving their own mode (fzf-lua answers in Terminal mode).
local function resume(win)
    local mode = vim.api.nvim_get_mode().mode
    if mode == 'n' then
        return insert(win)
    elseif mode:sub(1, 1) == 'i' then
        return
    end
    vim.api.nvim_create_autocmd('ModeChanged', {
        group = group,
        callback = function()
            local new = vim.v.event.new_mode
            if new == 'n' then
                vim.schedule(function()
                    if vim.api.nvim_get_mode().mode == 'n' then
                        insert(win)
                    end
                end)
            end
            -- Returning true deletes the autocmd.
            return new == 'n' or new:sub(1, 1) == 'i'
        end,
    })
end

-- The picker whose answer is being handled, so pickers it opens inherit its
-- `resume` window instead of returning to Insert mode in between.
local answering

-- vim.ui.select with the callback scheduled once; cb(nil, err) if the UI
-- throws. The picker opens on the next tick: one opened inside the prompt
-- callback would start in Normal mode, as Insert mode ends when the callback
-- returns. If wanted() is false by then, it is not opened and cb(nil) runs.
local function select(items, opts, cb, wanted)
    local picker = { resume = answering and answering.resume }
    if answering then
        answering.chained = true
    elseif vim.api.nvim_get_mode().mode == 'i' and vim.bo.filetype == 'boomer' then
        picker.resume = vim.api.nvim_get_current_win()
    end
    local answered = false
    local function answer(item, err)
        if not answered then
            answered = true
            vim.schedule(function()
                local outer = answering
                answering = picker
                local ok, e = pcall(cb, item, err)
                answering = outer
                if picker.resume and not picker.chained then
                    resume(picker.resume)
                end
                if not ok then
                    error(e, 0)
                end
            end)
        end
    end
    opts.format_item = opts.format_item or function(item)
        return item.label
    end
    vim.schedule(function()
        if wanted and not wanted() then
            return answer()
        end
        -- on_choice gets (item, idx); idx must not be taken for an error.
        local ok, err = pcall(vim.ui.select, items, opts, function(item)
            answer(item)
        end)
        if not ok then
            answer(nil, 'UI error: ' .. tostring(err))
        end
    end)
end

-- A chat's picker. Some UIs close without calling back (fzf-lua on <Esc>), so
-- nothing waits on a picker; a newer picker or a session change makes it
-- stale, and a stale answer is dropped.
local function pick(c, items, opts, cb)
    c.picks = (c.picks or 0) + 1
    local token = c.picks
    local function current()
        return c.picks == token and not c.closed and not c.dead
    end
    select(items, opts, function(item, err)
        if current() then
            cb(item, err)
        end
    end, current)
end

-- Preconditions ----------------------------------------------------------------

local function pending(c)
    return c.asking and not c.asking.done and c.asking
end

-- Why a command with precondition `gate` cannot run now, or nil. Gates
-- (named by commands.builtins):
--   none     always runs
--   session  needs an open session; may run during a turn (/usage)
--   idle     needs an open session with nothing in progress
--   queue    prompt text: like idle, but is queued during a turn or while
--            the session loads
--   switch   replaces the session: starts a chat if there is none, and
--            refuses to drop an unsent draft (unless the draft is the command
--            itself, `typed`)
--   agent    like switch, and also replaces an agent that exited
local function blocked(c, gate, typed)
    local switching = gate == 'switch' or gate == 'agent'
    if gate == 'none' or not c and switching or c and c.dead and gate == 'agent' then
        return nil
    elseif not c then
        return 'Open a conversation with :Boomer first'
    elseif c.dead then
        return 'The agent has exited; use :Boomer close, then :Boomer'
    elseif gate == 'queue' then
        return not c.loading and not c.session and 'No session; use /new or /resume' or nil
    elseif c.loading then
        return 'The conversation is still loading'
    elseif gate == 'session' then
        return not c.session and 'No session; use /new or /resume' or nil
    elseif pending(c) then
        return 'A permission request is waiting; :Boomer shows it again'
    elseif c.busy then
        return 'A turn is still active; wait or use :Boomer cancel'
    elseif switching then
        return not typed and c.view:draft() ~= '' and 'Send or clear the draft before switching'
            or nil
    end
    return not c.session and 'No session; use /new or /resume' or nil
end

-- Warn and return false if the command cannot run.
local function check(c, gate, typed)
    local msg = blocked(c, gate, typed)
    if msg then
        warn(msg)
        return false
    end
    return true
end

local function can_send(c, text)
    if not check(c, 'queue') then
        return false
    elseif not text:find('%S') then
        warn('The prompt is empty')
        return false
    end
    return true
end

-- Permissions -----------------------------------------------------------------
--
-- Requests are queued and shown one at a time. A request the agent settled
-- (cancel, turn end) is skipped, also while its picker is open; a late answer
-- to it is ignored. Dismissing the picker denies.

local ask

local function show(c, req)
    local items = { { label = 'Deny', result = req.deny } }
    vim.list_extend(items, req.choices)
    select(items, { prompt = 'Boomer: ' .. req.title }, function(item, err)
        if c.asking == req then
            c.asking = nil
        end
        if err then
            report(c, 'Permission ' .. err)
        end
        if not req.done and not c.closed then
            item = item or items[1]
            req.reply(item.result)
            c.view:write('Permission: ' .. item.label)
        end
        ask(c)
    end, function()
        return not req.done and not c.closed
    end)
end

-- Show the next queued request unless one is already shown.
function ask(c)
    if c.closed or pending(c) then
        return
    end
    c.asking = nil
    local req = table.remove(c.queue, 1)
    if not req then
        return
    elseif req.done then
        return ask(c)
    end
    c.asking = req
    local lines = { 'Permission: ' .. req.title }
    vim.list_extend(lines, req.details)
    c.view:write(table.concat(lines, '\n'))
    show(c, req)
end

-- Turns -----------------------------------------------------------------------

local drain

-- Run one agent turn; start(cb) issues it. `done` labels a completed turn
-- (default "completed"); other results are the agent's (e.g. "cancelled").
-- A finished turn sends the next queued prompt; a failed one returns the
-- queue to the draft.
local function turn(c, start, done)
    c.busy = true
    status(c, 'running')
    progress(c, 'running', 'running')
    local buf = c.view.buf
    start(function(err, result)
        c.busy, c.cancelling = false, false
        result = result == 'completed' and done or result or done or 'completed'
        if err then
            report(c, err.message)
            restore(c)
        else
            c.view:write('[' .. result .. ']')
        end
        if not c.dead then
            status(c, 'ready')
        end
        progress(c, err and 'failed' or 'success', err and 'failed' or result)
        vim.schedule(function()
            vim.api.nvim_exec_autocmds('User', {
                pattern = 'BoomerTurnDone',
                modeline = false,
                data = {
                    buf = buf,
                    result = not err and result or nil,
                    error = err and err.message,
                },
            })
        end)
        if not err then
            drain(c)
        end
    end)
end

-- Messages sent from outside the prompt line get unique IDs, so each starts
-- its own block in the view.
local echo_id = 0

-- Send text as a prompt. `echo` is shown as the user's message when the text
-- did not come from the prompt line itself (Ex commands, Lua).
local function send(c, text, echo)
    if echo then
        echo_id = echo_id + 1
        c.view:message('user', echo, 'boomer-echo-' .. echo_id)
    end
    turn(c, function(cb)
        c.client:prompt(text, cb)
    end)
end

-- Send the next queued prompt if the session is ready for it.
function drain(c)
    if c.busy or c.loading or c.dead or c.closed or not c.session then
        return
    end
    local e = table.remove(c.prompts, 1)
    if e then
        sync_queue(c)
        send(c, e.text, not e.shown and e.line or nil)
    end
end

-- Send prompt text now, or queue it while a turn runs or the session loads
-- (callers check the `queue` gate). `line` is the text as typed; `shown`: it
-- is already in the transcript.
local function submit(c, text, line, shown)
    if not (c.busy or c.loading or #c.prompts > 0) then
        return send(c, text, not shown and line or nil)
    end
    c.prompts[#c.prompts + 1] = { text = text, line = line, shown = shown }
    sync_queue(c)
    if shown then
        -- Appending inside the prompt callback, before Neovim adds the new
        -- prompt line, would leave an extra blank line after the next write.
        vim.schedule(function()
            c.view:write('[queued]')
        end)
    end
    drain(c)
end

-- Commands --------------------------------------------------------------------

-- Set while a command typed in the prompt runs: its line is already shown,
-- and the draft (being that line) does not block a switch.
local typed = false

local function unknown(name)
    return warn(
        ('Unknown command /%s; use /help, or start with // to send it as text'):format(name)
    )
end

-- Context passed to user commands (see :help boomer-user-commands).
local function context(args)
    local c = chat
    return {
        args = args,
        buf = c and c.view.buf,
        status = M.status(),
        send = function(text)
            if c and chat == c and check(c, 'idle') then
                send(c, text, text)
                return true
            end
        end,
        write = function(text)
            if c and chat == c then
                c.view:write(text)
            end
        end,
    }
end

-- Run a slash command: a builtin (M[name]), an agent command (sent as text)
-- or a user command (`run` or a `prompt` template). Returns true if it ran.
-- Text for the agent is queued during a turn; `shown`: the typed line is
-- already in the transcript.
local function run_command(c, name, args, from_prompt, shown)
    local item =
        commands.find(config.options.commands, c and c.agent_commands or {}, name, from_prompt)
    if not item then
        return unknown(name)
    end
    local line = '/' .. name .. (args ~= '' and (' ' .. args) or '')
    if item.source == 'builtin' then
        typed = from_prompt
        local ok, res = pcall(M[name], args ~= '' and args or nil)
        typed = false
        if not ok then
            error(res, 0)
        end
        return res
    elseif item.source == 'agent' then
        if check(c, 'queue') then
            submit(c, line, line, shown)
            return true
        end
        return
    end
    local spec = item.spec
    if spec.run then
        local ok, err = pcall(spec.run, args, context(args))
        if not ok then
            return warn('/' .. name .. ': ' .. tostring(err))
        end
        return true
    elseif not check(c, 'queue') then
        return
    end
    local ok, text = pcall(commands.expand, spec, args, context(args))
    if not ok then
        return warn('/' .. name .. ': ' .. tostring(text))
    elseif type(text) ~= 'string' or not text:find('%S') then
        return warn('/' .. name .. ' produced an empty prompt')
    end
    submit(c, text, line, shown)
    return true
end

-- Checked when Enter is pressed, before Neovim commits the draft, so a draft
-- that would be rejected stays editable. Returns the draft's gate if it can
-- be submitted.
local function can_submit(c, text)
    local cmd = commands.parse(text)
    if not cmd or cmd.text then
        return can_send(c, cmd and cmd.text or text) and 'queue'
    end
    local item = commands.find(config.options.commands, c.agent_commands, cmd.name, true)
    if not item then
        return unknown(cmd.name)
    end
    local gate = item.source == 'builtin' and item.spec.gate
        or item.source == 'user' and item.spec.run and 'none'
        or 'queue'
    return check(c, gate, true) and gate
end

-- Submit a draft typed in the prompt; `shown`: Neovim committed it into the
-- transcript. Returns true if it ran, was sent or was queued.
local function submit_draft(c, text, shown)
    local cmd = commands.parse(text)
    if cmd and cmd.name then
        return run_command(c, cmd.name, cmd.args, true, shown)
    elseif can_send(c, cmd and cmd.text or text) then
        submit(c, cmd and cmd.text or text, text, shown)
        return true
    end
end

-- Chat buffer -------------------------------------------------------------------

local function attach(c, view)
    local buf = view.buf
    vim.fn.prompt_setcallback(buf, function(text)
        -- Neovim already committed the input (<C-j> bypasses the <CR> guard),
        -- so a rejected draft is marked as such.
        local cmd = commands.parse(text)
        view:submitted(text)
        if not submit_draft(c, text, true) then
            view:write(cmd and cmd.name and '[not run]' or '[not sent]')
        end
    end)
    vim.fn.prompt_setinterrupt(buf, M.cancel)
    vim.keymap.set('i', '<CR>', function()
        local text = view:draft()
        local gate = can_submit(c, text)
        if not gate then
            return
        elseif gate == 'queue' and (c.busy or c.loading or #c.prompts > 0) then
            -- Not committed: a queued prompt enters the transcript when sent.
            if submit_draft(c, text, false) then
                view:set_draft('')
            end
            return
        end
        local enter = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
        vim.api.nvim_feedkeys(enter, 'in', false)
    end, { buffer = buf, desc = 'Submit Boomer prompt' })
    vim.keymap.set('n', '<C-c>', M.cancel, { buffer = buf, desc = 'Cancel Boomer turn' })
    -- Slash commands complete with <C-x><C-o>, and through 'complete' with
    -- <C-n> and 'autocomplete' (the omnifunc declines outside a command).
    vim.bo[buf].omnifunc = "v:lua.require'boomer'.omnifunc"
    vim.bo[buf].complete = 'o,' .. vim.go.complete
    -- :bd only unloads; wipe so no dead chat buffer lingers (deleting inside
    -- BufUnload is E937, hence the schedule).
    vim.api.nvim_create_autocmd('BufUnload', {
        group = group,
        buffer = buf,
        once = true,
        callback = function()
            if c.view == view and not c.closed then
                close(c)
            end
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
            end)
        end,
    })
end

local function new_view(c)
    c.view = require('boomer.view').new({
        winbar = config.options.winbar ~= false and "%{%v:lua.require'boomer'.winbar()%}",
        labels = { user = config.options.labels.prompt, agent = c.opts.label },
        window = config.options.window,
    })
    attach(c, c.view)
    status_mod.changed(c)
end

-- Show the chat's buffer in `wins` (replacing another buffer), or open it.
local function place(c, wins)
    for _, win in ipairs(wins or {}) do
        vim.api.nvim_win_set_buf(win, c.view.buf)
    end
    if not wins or #wins == 0 then
        c.view:open()
    end
end

-- Sessions ----------------------------------------------------------------------

-- Status fields that belong to a session, cleared when another one opens.
local session_fields = {
    session = vim.NIL,
    title = vim.NIL,
    model = vim.NIL,
    effort = vim.NIL,
    mode = vim.NIL,
    permissions = vim.NIL,
    context = vim.NIL,
    tokens = vim.NIL,
    cost = vim.NIL,
}

-- Open a session (a new one when id is nil) in the chat's current view.
local function load(c, id)
    c.loading, c.session, c.agent_commands = true, nil, {}
    -- Pickers for the previous session are now stale.
    c.picks = (c.picks or 0) + 1
    update(c, session_fields)
    status(c, id and 'loading' or 'starting')
    local function done(err)
        if c.dead or c.closed then
            return
        end
        c.loading = false
        if err then
            report(c, err.message)
            status(c, 'failed')
            restore(c)
            return
        end
        c.session = c.client.session
        update(c, { session = c.session, state = 'ready' })
        drain(c)
    end
    if id then
        c.client:load_session(id, c.opts.cwd, done)
    else
        c.client:new_session(c.opts.cwd, done)
    end
end

-- Swap a fresh buffer into the chat's windows and wipe the old one. The
-- client stays; only its current session changes.
local function switch(c, id)
    local old = c.view
    new_view(c)
    place(c, vim.fn.win_findbuf(old.buf))
    vim.api.nvim_buf_delete(old.buf, { force = true })
    load(c, id)
end

-- Pick a saved session. fresh: the chat has no session yet, so dismissing the
-- picker starts a new one. A picker that closes silently leaves it without
-- one; /new and /resume still work.
local function choose(c, fresh)
    local function dismiss(msg)
        if msg then
            warn(msg)
        end
        if fresh then
            load(c)
        end
    end
    c.client:list_sessions(c.opts.cwd, function(err, items)
        if c.dead or c.closed then
            return
        elseif err then
            return dismiss(err.message)
        elseif #items == 0 then
            return dismiss('No saved sessions for ' .. c.opts.cwd)
        end
        c.sessions = items
        if fresh then
            c.loading = false
            status(c, 'no session')
            restore(c)
        end
        pick(c, items, {
            prompt = 'Boomer sessions (' .. c.opts.name .. ' | ' .. c.opts.cwd .. '):',
            format_item = function(item)
                return (item.title:gsub('[\r\n]+', ' '))
                    .. (item.updated and (' | ' .. item.updated) or '')
                    .. (item.id == c.session and ' [current]' or '')
            end,
        }, function(item, e)
            if not item then
                return dismiss(e)
            elseif fresh then
                load(c, item.id)
            elseif item.id == c.session then
                c.view:open()
            elseif check(c, 'switch') then
                switch(c, item.id)
            end
        end)
    end)
end

-- Start a chat. o.agent: profile name (default agent when nil); o.pick: choose
-- a saved session; o.id: load that session; o.wins: windows to show it in.
local function start(o)
    local profile, perr = config.resolve(o.agent)
    if not profile then
        return warn(perr)
    end
    ---@type boomer.Chat
    local c = {
        opts = profile,
        queue = {},
        prompts = {},
        loading = true,
        agent_commands = {},
        state = { agent = profile.name, protocol = profile.protocol, cwd = profile.cwd },
    }
    chat = c
    new_view(c)
    status(c, 'starting')
    place(c, o.wins)
    ---@type boomer.Callbacks
    local on = {
        text = function(role, text, id)
            c.view:message(role, text, id)
        end,
        tool = function(title)
            c.view:write('[Tool: ' .. title .. ']')
        end,
        error = function(msg)
            report(c, msg)
        end,
        permission = function(req)
            c.queue[#c.queue + 1] = req
            ask(c)
        end,
        exit = function(msg)
            report(c, msg)
            c.dead, c.loading, c.queue = true, false, {}
            status(c, 'closed')
            restore(c)
        end,
        status = function(fields)
            if not c.closed then
                update(c, fields)
            end
        end,
        commands = function(list)
            c.agent_commands = {}
            for _, cmd in ipairs(list) do
                c.agent_commands[cmd.name] = cmd
            end
        end,
    }
    local client, err = require(config.protocols[profile.protocol]).start(profile, on, function(e)
        if c.dead or c.closed then
            return
        elseif e then
            fail(c, e.message)
        elseif o.pick then
            choose(c, true)
        else
            load(c, o.id)
        end
    end)
    c.client = client
    if not client then
        fail(c, err)
    end
    return c
end

-- Public API (see :help boomer-lua) -------------------------------------------
--
-- Command functions return true when they ran (or started running), and
-- nil after warning otherwise.

-- Open or focus the chat, starting one if needed; shows a permission request
-- again if its picker was closed without an answer. Returns the chat buffer.
---@return integer?
function M.open()
    if chat then
        chat.view:open()
        local req = pending(chat)
        if req then
            show(chat, req)
            return chat.view.buf
        end
    else
        start({})
    end
    if chat and vim.api.nvim_get_current_buf() == chat.view.buf then
        insert(vim.api.nvim_get_current_win())
    end
    return chat and chat.view.buf
end

local function apply(c, setting, choice, finish)
    c.client:configure(setting.id, choice.value, function(e)
        finish(e and e.message)
        if not e then
            c.view:write('[Setting: ' .. setting.id .. ' = ' .. choice.label .. ']')
        end
    end)
end

-- Run run(c, list, finish) with the session's settings; finish(err) reports a
-- failure. local_only: use what the client knows without asking the agent.
local function with_settings(run, local_only)
    local c = chat
    if not check(c, 'idle') then
        return
    end
    local function finish(err)
        if err then
            report(c, err)
        end
    end
    if local_only then
        run(c, c.client:setting_list(), finish)
        return true
    end
    c.client:settings(function(err, list)
        if c.closed or c.dead then
            return
        elseif err then
            return finish(err.message)
        end
        run(c, list, finish)
    end)
    return true
end

-- Pick a setting, then its value.
function M.settings()
    return with_settings(function(c, list, finish)
        local settings = {}
        for _, s in ipairs(list) do
            if #s.choices > 0 then
                local label = s.label .. (s.current ~= nil and (' | ' .. tostring(s.current)) or '')
                settings[#settings + 1] = vim.tbl_extend('force', s, { label = label })
            end
        end
        if #settings == 0 then
            return warn('This session advertises no selectable settings')
        end
        pick(c, settings, { prompt = 'Boomer setting:' }, function(setting, e)
            if not setting then
                return finish(e)
            end
            pick(
                c,
                setting.choices,
                { prompt = 'Boomer ' .. setting.id .. ':' },
                function(choice, e2)
                    -- The session may have become busy while the picker was open.
                    if not choice or not check(c, 'idle') then
                        return finish(e2)
                    end
                    apply(c, setting, choice, finish)
                end
            )
        end)
    end)
end

-- Set the setting of `key` (a util.categories name) to `value`, or pick it
-- when value is nil. Permission presets are known locally; models and
-- efforts may need the agent.
local function set_category(key, noun, value)
    local category = util.categories[key]
    return with_settings(function(c, list, finish)
        local setting = util.find(list, category)
        if not setting or #setting.choices == 0 then
            return warn('This agent offers no ' .. noun .. ' setting')
        elseif value then
            local choice = util.choice(setting, value)
            if not choice then
                return warn('Unknown ' .. noun .. ': ' .. value)
            end
            return apply(c, setting, choice, finish)
        end
        pick(c, setting.choices, {
            prompt = 'Boomer ' .. noun .. ':',
            format_item = function(item)
                return item.label .. (item.value == setting.current and ' [current]' or '')
            end,
        }, function(choice, e)
            if not choice or not check(c, 'idle') then
                return finish(e)
            end
            apply(c, setting, choice, finish)
        end)
    end, key == 'permissions')
end

---@param value? string Model ID or name; picks when nil.
function M.model(value)
    return set_category('model', 'model', value)
end

---@param value? string
function M.effort(value)
    return set_category('effort', 'reasoning effort', value)
end

-- Prefer the agent's own command (ACP agents may advertise one).
---@param value? string
function M.permissions(value)
    local c = chat
    if c and c.agent_commands.permissions then
        if not check(c, 'idle') then
            return
        end
        local line = '/permissions' .. (value and (' ' .. value) or '')
        send(c, line, not typed and line or nil)
        return true
    end
    return set_category('permissions', 'permissions', value)
end

-- Load session `id`, or pick a saved one.
---@param id? string
function M.resume(id)
    local c = chat
    if not check(c, 'switch', typed) then
        return
    elseif not c then
        start({ pick = not id, id = id })
    elseif not id then
        choose(c, false)
    elseif id == c.session then
        c.view:open()
    else
        switch(c, id)
    end
    return true
end

-- Start a new session with the same agent.
function M.new()
    if not check(chat, 'switch', typed) then
        return
    elseif not chat then
        start({})
    else
        switch(chat)
    end
    return true
end

-- Replace the chat with one for another agent profile, in the same windows,
-- or pick the agent.
---@param name? string
function M.agent(name)
    local c = chat
    if not check(c, 'agent', typed) then
        return
    elseif not name then
        local current = c and c.opts.name
        local opts = {
            prompt = 'Boomer agent:',
            format_item = function(n)
                return ('%s (%s)%s'):format(
                    n,
                    config.options.agents[n].protocol,
                    n == current and ' [current]' or ''
                )
            end,
        }
        local function chosen(choice)
            if choice and chat == c then
                M.agent(choice)
            end
        end
        local names = config.installed_agent_names(current)
        if c and not c.dead then
            pick(c, names, opts, chosen)
        else
            select(names, opts, chosen)
        end
        return true
    elseif not config.options.agents[name] then
        return warn('Unknown agent: ' .. name)
    elseif c and c.opts.name == name and not c.dead then
        c.view:open()
        return true
    end
    if c then
        local old = c.view.buf
        local wins = vim.fn.win_findbuf(old)
        close(c)
        start({ agent = name, wins = wins })
        vim.api.nvim_buf_delete(old, { force = true })
    else
        start({ agent = name })
    end
    return true
end

-- Write context, token and cost usage into the chat.
function M.usage()
    local c = chat
    if not check(c, 'session') then
        return
    end
    c.view:write(table.concat(status_mod.usage(c.state), '\n'))
    return true
end

-- Compact the conversation. Prefers the agent's own command (it may take
-- focus instructions), else native compaction.
---@param focus? string
function M.compact(focus)
    local c = chat
    if not check(c, 'idle') then
        return
    elseif c.agent_commands.compact then
        local line = '/compact' .. (focus and (' ' .. focus) or '')
        send(c, line, not typed and line or nil)
    elseif not c.client.compact then
        return warn('This agent cannot compact the conversation')
    elseif focus then
        return warn('This agent takes no compaction instructions')
    else
        turn(c, function(cb)
            c.client:compact(cb)
        end, 'compacted')
    end
    return true
end

-- List the commands in the chat, or open the help without one.
function M.help()
    local c = chat
    local lines = commands.help(
        commands.list(config.options.commands, c and c.agent_commands or {}, c ~= nil)
    )
    if c then
        c.view:write(table.concat(lines, '\n'))
    elseif not pcall(vim.cmd.help, 'boomer-commands') then
        vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO, { title = 'Boomer' })
    end
    return true
end

-- Cancel the running turn. Queued prompts return to the draft, also when no
-- turn runs yet (queued while the session loads).
function M.cancel()
    local c = chat
    local queued = c and #c.prompts > 0
    if queued then
        restore(c)
    end
    if not c or not c.busy then
        return queued or warn('No active Boomer turn')
    end
    if not c.cancelling then
        c.cancelling = true
        status(c, 'cancelling')
        c.client:cancel(function(err)
            c.cancelling = false
            report(c, 'cancel failed: ' .. err.message)
            status(c, 'running')
        end)
    end
    return true
end

-- Stop the agent and wipe the chat buffer.
function M.close()
    local c = chat
    if c then
        close(c)
        if vim.api.nvim_buf_is_valid(c.view.buf) then
            vim.api.nvim_buf_delete(c.view.buf, { force = true })
        end
    end
end

-- Run a command line such as "model gpt-5" or "/usage", as typed after
-- :Boomer. An empty line opens the chat.
---@param line? string
function M.run(line)
    line = vim.trim(line or '')
    if line == '' then
        return M.open() and true
    end
    local name, args = line:match('^/?(%S+)%s*(.-)%s*$')
    return run_command(chat, name, args, false)
end

-- A copy of the chat status, with the chat buffer (nil without a chat).
---@return boomer.Status?
function M.status()
    if not chat then
        return nil
    end
    local st = vim.deepcopy(chat.state)
    st.buf = chat.view.buf
    return st
end

-- The status as plain text for a 'statusline' ('' without a chat).
function M.statusline()
    return chat and status_mod.statusline(M.status()) or ''
end

-- 'winbar' expression for chat windows; a function `winbar` option formats it.
function M.winbar()
    -- nvim_eval_statusline() does not set g:statusline_winid.
    local c, win = chat, vim.g.statusline_winid or vim.api.nvim_get_current_win()
    if
        not c
        or not vim.api.nvim_win_is_valid(win)
        or vim.api.nvim_win_get_buf(win) ~= c.view.buf
    then
        return ''
    end
    local fmt = config.options.winbar
    if type(fmt) == 'function' then
        local ok, s = pcall(fmt, M.status())
        return ok and tostring(s or '') or ''
    end
    return status_mod.winbar(M.status())
end

-- Completion ------------------------------------------------------------------

-- Completion items for commands typed in the prompt.
local function command_items(c, base)
    local items = {}
    for _, item in ipairs(commands.list(config.options.commands, c.agent_commands, true)) do
        local word = '/' .. item.name
        if vim.startswith(word, base) then
            items[#items + 1] = {
                word = word,
                menu = item.hint,
                info = item.desc,
                kind = item.source:sub(1, 1),
            }
        end
    end
    return items
end

-- Values for a command's argument. Completion must not block on the agent,
-- so settings come from what the client already knows.
local function arg_candidates(name)
    local c = chat
    local item = commands.find(config.options.commands, c and c.agent_commands or {}, name, false)
    if not item then
        return {}
    end
    local spec, kind = item.spec, item.source == 'builtin' and item.spec.complete
    if item.source == 'user' and spec.complete then
        if type(spec.complete) == 'function' then
            local ok, list = pcall(spec.complete, c and M.status())
            return ok and type(list) == 'table' and list or {}
        end
        return spec.complete
    elseif kind == 'agent' then
        return config.installed_agent_names(c and c.opts.name)
    elseif kind == 'session' then
        return vim.tbl_map(function(s)
            return s.id
        end, c and c.sessions or {})
    elseif kind and util.categories[kind] and c and c.client and not c.dead then
        local s = util.find(c.client:setting_list(), util.categories[kind])
        return vim.tbl_map(function(choice)
            return tostring(choice.value)
        end, s and s.choices or {})
    end
    return {}
end

local function prefixed(list, lead)
    return vim.tbl_filter(function(s)
        return vim.startswith(s, lead)
    end, list)
end

-- :Boomer completion: subcommands, then their arguments.
function M.complete(lead, cmdline, pos)
    local before = cmdline:sub(1, pos):gsub('^%s*%S+%s*', '', 1)
    local name = before:match('^(%S+)%s')
    if not name then
        local names = vim.tbl_map(function(item)
            return item.name
        end, commands.list(
            config.options.commands,
            chat and chat.agent_commands or {},
            false
        ))
        return prefixed(names, lead)
    end
    return prefixed(arg_candidates(name), lead)
end

-- 'omnifunc' for the chat buffer: a command name at the start of the draft,
-- then its argument. Elsewhere it returns -3, which ends <C-x><C-o> quietly
-- and lets 'complete' move on to its other sources.
local completing
function M.omnifunc(findstart, base)
    local c = chat
    if not c or c.view.buf ~= vim.api.nvim_get_current_buf() then
        return findstart == 1 and -3 or {}
    end
    if findstart == 1 then
        local row, col = c.view:row()
        local cursor = vim.api.nvim_win_get_cursor(0)
        if cursor[1] - 1 ~= row then
            return -3
        end
        local text = vim.api.nvim_get_current_line():sub(col + 1, cursor[2])
        if text:match('^/[^%s/]*$') then
            completing = nil
            return col
        end
        local name, arg = text:match('^/([^%s/]+)%s+(%S*)$')
        if name then
            completing = name
            return cursor[2] - #arg
        end
        return -3
    end
    if completing then
        return vim.tbl_map(function(s)
            return { word = s }
        end, prefixed(arg_candidates(completing), base))
    end
    return command_items(c, base)
end

-- Don't block exit: SIGTERM now, the agent's own shutdown does the rest.
vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
        if chat and chat.client then
            chat.client:close(true)
        end
    end,
})

return M
