-- The chat: one at a time, made of an agent client (boomer.codex or
-- boomer.acp), its current session, and the prompt buffer showing it
-- (boomer.view). Switching sessions keeps the client and swaps in a fresh
-- buffer; switching agents, or restarting one that exited, replaces both.
--
-- Data flow: <CR> in the prompt and :Boomer commands call into this module,
-- which drives the client; the client talks JSON-RPC to the agent
-- (boomer.rpc) and reports back through the `on` callbacks set up in start().
-- All callbacks run on the main loop, so no locking is needed.

---Callbacks an adapter reports through.
---@class boomer.Callbacks
---@field text fun(role: 'user'|'agent', text: string, id: string?) Message text (streamed).
---@field tool fun(title: string) A tool call started (or failed).
---@field diff fun(diffs: boomer.Diff[]) A tool call's file changes; once per tool call.
---@field error fun(msg: string)
---@field permission fun(req: boomer.Permission) The agent asks before acting.
---@field settled fun() The agent withdrew a permission request (set its `done`).
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
---@field diffs? boomer.Diff[] File changes to approve, unless already shown.
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
---@field rate_limits? fun(self, cb: fun()) Refresh the `limits` status before /usage.
---@field settings fun(self): boomer.Setting[]
---@field configure fun(self, id: string, value: any, cb: fun(err: table?)) Codex: from the next turn.

local config = require('boomer.config')
local util = require('boomer.util')
local commands = require('boomer.commands')
local status_mod = require('boomer.status')
local M = {}

---@class boomer.Chat
---@field opts boomer.Profile
---@field cwd string Working directory of the current session (see config.cwd()).
---@field client? boomer.Client nil if the agent failed to start.
---@field view boomer.View Shows the current session.
---@field state boomer.Status
---@field session? string Open session ID (set once it is ready).
---@field agent_commands table<string, table> Slash commands advertised by the agent.
---@field sessions? table[] Last listed saved sessions (for their titles).
---@field queue boomer.Permission[] Permission requests waiting to be shown.
---@field prompts boomer.Queued[] Prompts waiting for the turn or session to be ready.
---@field asking? boomer.Permission The request being shown.
---@field loading? boolean Starting the agent or opening a session.
---@field busy? boolean A turn is running.
---@field cancelling? boolean
---@field dead? boolean The agent exited or failed to start.
---@field closed? boolean Closed by the user; callbacks are ignored.
---@field picks? integer Picker generation; see pick().
---@field announce? 'agent'|'session' Confirm the switch once the session is ready.

---A queued prompt.
---@class boomer.Queued
---@field text string Sent to the agent.
---@field line string As typed: shown when sent, or put back into the draft.
---@field draft? string Put back into the draft instead of `line`.

---@type boomer.Chat?
local chat
local group = vim.api.nvim_create_augroup('Boomer', { clear = true })

-- Validate and apply options; see :help boomer-config.
---@param opts? table
function M.setup(opts)
    config.set(opts)
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
    c.view:set_busy(status_mod.busy(c.state.state))
    status_mod.changed(c)
end

local function status(c, s)
    update(c, { state = s })
end

-- Write a warning or error into the chat's transcript; also notify while the
-- chat is hidden, and only notify without a chat.
local function say(c, kind, msg, level)
    msg = msg:gsub('%s+$', '')
    if c and not c.closed and c.view:valid() then
        c.view:write(kind .. ': ' .. msg, 'Boomer' .. kind)
        if c.view:visible() then
            return
        end
    end
    vim.notify(msg, level, { title = 'Boomer' })
end

-- Warn in chat `c` (default: the current chat) and return nil, so command
-- functions can `return warn(...)`.
local function warn(msg, c)
    say(c or chat, 'Warning', msg, vim.log.levels.WARN)
    return nil
end

-- Write an error into the chat. After the agent exits, later errors only
-- repeat the exit message, so they are dropped.
local function report(c, msg)
    if not c.dead then
        say(c, 'Error', msg, vim.log.levels.ERROR)
    end
end

-- Prompt queue ------------------------------------------------------------------
--
-- Prompts submitted while a turn runs or the session loads wait in c.prompts
-- and are sent one per turn, in order (drain). They are shown as virtual
-- lines until sent. A cancel, a failed turn or the loss of the session puts
-- them back into the draft (restore).

-- Whether new prompts must wait in the queue.
local function occupied(c)
    return c.busy or c.loading or #c.prompts > 0
end

local function sync_queue(c)
    c.view:set_queued(vim.tbl_map(function(e)
        return e.line
    end, c.prompts))
    update(c, { queued = #c.prompts > 0 and #c.prompts or vim.NIL })
end

-- Put text back into the draft, before what is being typed.
local function unshift(view, text)
    if text == '' or not view:valid() then
        return
    end
    local current = view:draft()
    view:set_draft(current ~= '' and (text .. '\n\n' .. current) or text)
end

-- Move the queued prompts into the draft.
local function restore(c)
    if #c.prompts == 0 then
        return
    end
    local parts = vim.tbl_map(function(e)
        return e.draft or e.line
    end, c.prompts)
    c.prompts = {}
    sync_queue(c)
    unshift(c.view, table.concat(parts, '\n\n'))
end

-- The agent exited or failed to start: report why, return the queue to the
-- draft and stop the process (a no-op once it has exited).
local function fail(c, msg)
    report(c, msg)
    c.dead, c.loading, c.queue = true, false, {}
    status(c, 'exited')
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
end

-- Pickers --------------------------------------------------------------------
--
-- vim.ui.select pickers leave Insert mode. A picker opened from Insert mode in
-- the chat (typing /model, or a permission request while typing) returns
-- there once it is answered and Normal mode is back in the chat window. A
-- picker opened while another's answer is handled (the next permission
-- request) inherits this, and only the last one returns to Insert mode.

-- The picker whose answer is being handled, if any.
local answering

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

-- Return to Insert mode in `win` once in Normal mode. Some pickers answer
-- before leaving their own mode (fzf-lua's terminal is still in Terminal
-- mode), so then wait for the next mode change.
local function resume(win)
    local mode = vim.api.nvim_get_mode().mode
    if mode == 'n' then
        insert(win)
    elseif mode:sub(1, 1) ~= 'i' then
        vim.api.nvim_create_autocmd('ModeChanged', {
            once = true,
            callback = function()
                if vim.v.event.new_mode == 'n' then
                    vim.schedule(function()
                        insert(win)
                    end)
                end
            end,
        })
    end
end

-- vim.ui.select with the callback scheduled once; cb(nil, err) if the UI
-- throws. The picker opens on the next tick, after the mapping that opened
-- it. If wanted() is false by then, it is not opened and cb(nil) runs.
local function select(items, opts, cb, wanted)
    local picker = {}
    if answering then
        picker.win, answering.chained = answering.win, true
    elseif vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' and vim.bo.filetype == 'boomer' then
        picker.win = vim.api.nvim_get_current_win()
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
                if picker.win and not picker.chained then
                    resume(picker.win)
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

local no_session = 'No session; use /new or /resume'

-- Why a command with precondition `gate` cannot run now, or nil. Gates:
--   none     always runs
--   session  needs an open session; may run during a turn
--   queue    prompt text: needs a session, or one loading; queued while busy
--   idle     needs an open session with nothing in progress
--   switch   replaces the session: needs nothing in progress; starts a chat
--            if there is none, or restarts an agent that exited
local function blocked(c, gate)
    if gate == 'none' or gate == 'switch' and (not c or c.dead) then
        return nil
    elseif not c then
        return 'Open a conversation with :Boomer first'
    elseif c.dead then
        return 'The agent has exited; :Boomer restarts it'
    elseif gate == 'queue' then
        return not c.loading and not c.session and no_session or nil
    elseif c.loading then
        return 'The conversation is still loading'
    elseif gate == 'session' then
        return not c.session and no_session or nil
    elseif pending(c) then
        return 'A permission request is waiting; :Boomer shows it again'
    elseif occupied(c) then
        return 'A turn is still active; wait or use /cancel'
    elseif gate == 'idle' then
        return not c.session and no_session or nil
    end
end

-- Warn and return false if the command cannot run.
local function check(c, gate)
    local msg = blocked(c, gate)
    if msg then
        warn(msg, c)
        return false
    end
    return true
end

local function can_send(c, text)
    if not check(c, 'queue') then
        return false
    elseif not text:find('%S') then
        warn('The prompt is empty', c)
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
    if req.diffs then
        c.view:diff(req.diffs)
    end
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
    local buf = c.view.buf
    start(function(err, result)
        c.busy, c.cancelling = false, false
        if result == nil or result == 'completed' then
            result = done or 'completed'
        end
        if err then
            report(c, err.message)
            restore(c)
        else
            c.view:write('[' .. result .. ']')
        end
        if not c.dead then
            status(c, 'ready')
        end
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

-- Each user message gets a unique ID, so each starts its own block in the
-- view.
local echo_id = 0

-- Show a prompt or command line as the user's message.
local function echo(c, line)
    echo_id = echo_id + 1
    c.view:message('user', line, 'boomer-echo-' .. echo_id)
end

-- Send text as a prompt, shown as `line`.
local function send(c, text, line)
    echo(c, line)
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
        send(c, e.text, e.line)
    end
end

-- Ask the agent to stop the running turn; the turn ends once it has.
local function interrupt(c)
    if c.cancelling then
        return
    end
    c.cancelling = true
    status(c, 'cancelling')
    c.client:cancel(function(err)
        c.cancelling = false
        report(c, 'cancel failed: ' .. err.message)
        status(c, 'running')
    end)
end

-- Send prompt text now, or queue it while a turn runs or the session loads
-- (callers check the `queue` gate). `line` is shown as the user's message.
-- `now` puts it at the front of the queue and interrupts the running turn,
-- so it is sent once the agent has stopped; the rest of the queue follows.
-- `draft` replaces `line` if the prompt returns to the draft.
local function submit(c, text, line, now, draft)
    if not occupied(c) then
        return send(c, text, line)
    end
    local e = { text = text, line = line, draft = draft }
    table.insert(c.prompts, now and 1 or #c.prompts + 1, e)
    sync_queue(c)
    if now and c.busy then
        interrupt(c)
    end
    drain(c)
end

-- Commands --------------------------------------------------------------------

local function unknown(name)
    return warn(
        ('Unknown command /%s; use /help, or start with // to send it as text'):format(name)
    )
end

-- Warn and return true if `args` were given to a builtin that takes none
-- (one without a `hint`).
local function extra_args(item, args)
    if item.source == 'builtin' and not item.spec.hint and args ~= '' then
        warn(('/%s takes no arguments'):format(item.name))
        return true
    end
    return false
end

-- Context passed to user `run` commands (see :help boomer-user-commands);
-- `now` makes send() go ahead of the queue (see submit). Once the session
-- (and so the view) is replaced, send() and write() do nothing.
local function context(args, now)
    local c = chat
    local view = c and c.view
    local function current()
        return c and chat == c and c.view == view
    end
    return {
        args = args,
        buf = view and view.buf,
        status = M.status(),
        send = function(text)
            if current() and can_send(c, text) then
                submit(c, text, text, now)
                return true
            end
        end,
        write = function(text)
            if current() then
                c.view:write(text)
            end
        end,
    }
end

-- Run a slash command: a builtin (M[name]), an agent command (sent as text)
-- or a user command (`run` or a `prompt` template). Returns true if it ran,
-- was sent or was queued. `now` sends a prompt it makes at once (see submit).
local function run_command(c, name, args, now)
    local item =
        commands.find(config.options.commands, c and c.agent_commands or {}, name)
    if not item then
        return unknown(name)
    elseif extra_args(item, args) then
        return
    elseif item.source == 'builtin' then
        return M[name](args ~= '' and args or nil, now)
    end
    local line = '/' .. name .. (args ~= '' and (' ' .. args) or '')
    local spec = item.spec
    if item.source == 'user' and spec.run then
        if c then
            echo(c, line)
        end
        local ok, err = pcall(spec.run, args, context(args, now))
        if not ok then
            return warn('/' .. name .. ': ' .. tostring(err))
        end
        return true
    elseif not check(c, 'queue') then
        return
    end
    local text = item.source == 'user' and commands.expand(spec, args) or line
    if not text:find('%S') then
        return warn('/' .. name .. ' produced an empty prompt')
    end
    submit(c, text, line, now)
    return true
end

-- Submit a draft typed in the prompt; one that cannot be submitted now goes
-- back into the draft, after a warning saying why. A blank draft is ignored.
-- `now` sends a prompt at once (see submit).
local function enter(c, view, text, now)
    if not text:find('%S') then
        return unshift(view, text)
    end
    local cmd = commands.parse(text)
    local ok
    if cmd and cmd.name then
        ok = run_command(c, cmd.name, cmd.args, now)
    elseif can_send(c, cmd and cmd.text or text) then
        submit(c, cmd and cmd.text or text, text, now)
        ok = true
    end
    if not ok then
        unshift(view, text)
    end
end

-- Cancel the running turn and return the queued prompts to the draft, also
-- when no turn runs yet (queued while the session loads). `line` is echoed
-- first if there is something to cancel.
local function cancel(c, line)
    if not c or #c.prompts == 0 and not c.busy then
        return warn('Nothing to cancel', c)
    end
    if line then
        echo(c, line)
    end
    restore(c)
    if c.busy then
        interrupt(c)
    end
    return true
end

-- Chat buffer -------------------------------------------------------------------

local next_mode

local function attach(c, view)
    local buf = view.buf
    -- <CR> takes the draft itself, so Neovim never commits it: every user
    -- message is written when it is sent.
    vim.keymap.set('i', '<CR>', function()
        if vim.fn.pumvisible() == 1 and vim.fn.complete_info({ 'selected' }).selected ~= -1 then
            vim.api.nvim_feedkeys(vim.keycode('<C-y>'), 'n', false)
            return
        end
        local text = view:draft()
        if not text:find('%S') then
            return
        end
        view:set_draft('')
        enter(c, view, text)
    end, { buffer = buf, desc = 'Submit Boomer prompt' })
    -- i_CTRL-R puts a linewise register above the cursor line, ahead of the
    -- text typed: insert its lines at the cursor instead, as if typed.
    vim.keymap.set('i', '<C-R>', function()
        local ok, reg = pcall(vim.fn.getcharstr)
        local literal = ok and reg:match('^[\15\16\18]$') and reg or ''
        if literal ~= '' then
            ok, reg = pcall(vim.fn.getcharstr)
        end
        if not ok then
            return
        end
        if reg:match('^[%w"*+]$') and vim.fn.getregtype(reg) == 'V' then
            local lines = vim.fn.getreg(reg, 1, true)
            lines[#lines + 1] = ''
            vim.api.nvim_put(lines, 'c', false, true)
        else
            vim.api.nvim_feedkeys(vim.keycode('<C-R>') .. literal .. reg, 'ni', false)
        end
    end, { buffer = buf, desc = 'Insert register at the cursor' })
    -- Keys such as <C-j> and <kEnter> commit the draft without the mapping.
    vim.fn.prompt_setcallback(buf, function(text)
        view:uncommit(text)
        vim.schedule(function()
            if view:valid() then
                enter(c, view, text)
            end
        end)
    end)
    vim.fn.prompt_setinterrupt(buf, function()
        cancel(c)
    end)
    vim.keymap.set('n', '<C-c>', function()
        cancel(c)
    end, { buffer = buf, desc = 'Cancel Boomer turn' })
    -- Send the draft ahead of the queue, interrupting the turn; a blank draft
    -- interrupts it for the next queued prompt.
    vim.keymap.set('n', '<S-CR>', function()
        local text = view:draft()
        if text:find('%S') then
            view:set_draft('')
            enter(c, view, text, true)
        elseif #c.prompts == 0 then
            warn('Nothing to send', c)
        elseif c.busy then
            interrupt(c)
        end
    end, { buffer = buf, desc = 'Send Boomer prompt now' })
    -- Agents' own UIs switch modes with <S-Tab>. The completion menu keeps it;
    -- the change waits for the expr mapping's textlock to end.
    vim.keymap.set({ 'i', 'n', 'x' }, '<S-Tab>', function()
        if vim.fn.pumvisible() == 1 then
            return '<C-p>'
        end
        vim.schedule(next_mode)
        return ''
    end, { buffer = buf, expr = true, desc = 'Next Boomer mode' })
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

-- A fresh buffer for the chat, with `draft` carried over from the last one.
local function new_view(c, draft)
    c.view = require('boomer.view').new({
        winbar = config.options.winbar ~= false and "%{%v:lua.require'boomer'.winbar()%}",
        labels = { user = config.options.labels.prompt, agent = c.opts.label },
        signs = config.options.signs
            and { user = config.options.signs.prompt, agent = config.options.signs.agent },
        window = config.options.window,
        cwd = c.cwd,
        diff_lines = config.options.diff_lines,
    })
    attach(c, c.view)
    unshift(c.view, draft or '')
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

-- A session title on one line; nil if it is blank.
local function one_line(title)
    if type(title) == 'string' and title:find('%S') then
        return (title:gsub('[\r\n]+', ' '))
    end
end

-- The open session as /resume names it: its title (reported, or listed by
-- /resume), or its ID.
local function session_name(c)
    local title = c.state.title
    for _, s in ipairs(not title and c.sessions or {}) do
        if s.id == c.session then
            title = s.title
        end
    end
    return one_line(title) or c.session
end

-- Open a session (a new one when id is nil) for working directory `cwd`
-- (default: the chat's) in the chat's current view. Once it is ready, a
-- pending c.announce ('agent' or 'session', set by the command that switched)
-- is confirmed in the transcript.
local function load(c, id, cwd)
    c.loading, c.session, c.agent_commands = true, nil, {}
    -- Pickers for the previous session are now stale.
    c.picks = (c.picks or 0) + 1
    c.cwd = cwd or c.cwd
    c.view.cwd = c.cwd
    update(c, vim.tbl_extend('force', session_fields, { cwd = c.cwd }))
    status(c, id and 'loading' or 'starting')
    local function done(err)
        if c.dead or c.closed then
            return
        end
        local announce = c.announce
        c.loading, c.announce = false, nil
        if err then
            report(c, err.message)
            status(c, 'no session')
            restore(c)
            return
        end
        c.session = c.client.session
        update(c, { session = c.session, state = 'ready' })
        if announce == 'agent' then
            c.view:write('[Agent: ' .. c.opts.name .. ']')
        elseif announce == 'session' then
            c.view:write('[Session: ' .. (id and session_name(c) or 'new') .. ']')
        end
        drain(c)
    end
    if id then
        c.client:load_session(id, c.cwd, done)
    else
        c.client:new_session(c.cwd, done)
    end
end

-- Swap a fresh buffer, with the draft, into the chat's windows and wipe the
-- old one. The client stays; only its current session changes, to session
-- `id` (a new one when nil) for working directory `cwd`.
local function switch(c, id, cwd)
    local old = c.view
    new_view(c, old:draft())
    place(c, vim.fn.win_findbuf(old.buf))
    vim.api.nvim_buf_delete(old.buf, { force = true })
    c.announce = 'session'
    load(c, id, cwd)
end

-- Focus the chat and confirm that what a command selects, `what`, is already
-- active.
local function already(c, line, what)
    echo(c, line)
    c.view:open()
    c.view:write('[' .. what .. ' (current)]')
end

-- Pick a saved session for Neovim's current working directory. fresh: the
-- chat has no session yet, so dismissing the picker starts a new one. A
-- picker that closes silently leaves it without one; /new and /resume still
-- work.
local function choose(c, fresh)
    -- Read once: listing and loading agree even after a :cd meanwhile. A fresh
    -- chat uses the directory its command ran in, before the agent started.
    local cwd = fresh and c.cwd or config.cwd()
    local function dismiss(msg)
        if msg then
            warn(msg, c)
        end
        if fresh then
            load(c, nil, cwd)
        end
    end
    local view = c.view
    c.client:list_sessions(cwd, function(err, items)
        if c.dead or c.closed or c.view ~= view then
            return
        elseif err then
            return dismiss(err.message)
        elseif #items == 0 then
            return dismiss('No saved sessions for ' .. cwd)
        end
        c.sessions = items
        if fresh then
            c.loading = false
            status(c, 'no session')
            restore(c)
        end
        pick(c, items, {
            prompt = 'Boomer sessions (' .. c.opts.name .. ' | ' .. cwd .. '):',
            format_item = function(item)
                return (one_line(item.title) or item.id)
                    .. (item.updated and (' | ' .. item.updated) or '')
                    .. (item.id == c.session and ' [current]' or '')
            end,
        }, function(item, e)
            if not item then
                return dismiss(e)
            elseif fresh then
                load(c, item.id, cwd)
            elseif item.id == c.session then
                already(c, '/resume ' .. item.id, 'Session: ' .. session_name(c))
            elseif check(c, 'switch') then
                switch(c, item.id, cwd)
            end
        end)
    end)
end

-- Start a chat. o.agent: profile name (default agent when nil); o.pick: choose
-- a saved session; o.id: load that session; o.wins: windows to show it in;
-- o.draft: initial draft; o.announce: confirm it once ready (see load()).
local function start(o)
    local profile, perr = config.resolve(o.agent)
    if not profile then
        return warn(perr)
    end
    ---@type boomer.Chat
    local c = {
        opts = profile,
        cwd = profile.cwd,
        queue = {},
        prompts = {},
        loading = true,
        announce = o.announce,
        agent_commands = {},
        state = { agent = profile.name, protocol = profile.protocol, cwd = profile.cwd },
    }
    chat = c
    new_view(c, o.draft)
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
        diff = function(diffs)
            c.view:diff(diffs)
        end,
        error = function(msg)
            report(c, msg)
        end,
        permission = function(req)
            c.queue[#c.queue + 1] = req
            ask(c)
        end,
        -- The request shown may be gone: show the next one.
        settled = function()
            ask(c)
        end,
        exit = function(msg)
            fail(c, msg)
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

-- Start a chat in place of `c`, in its windows and with its draft; or the
-- first one.
local function restart(c, o)
    if not c then
        return start(o)
    end
    local old = c.view.buf
    o.wins, o.draft = vim.fn.win_findbuf(old), c.view:draft()
    close(c)
    start(o)
    vim.api.nvim_buf_delete(old, { force = true })
end

-- Public API (see :help boomer-api) --------------------------------------------
--
-- Command functions return true when they ran (or started running), and nil
-- after warning otherwise. One that runs shows its line as the user's
-- message, then its result; /new, /resume and /agent write their result in
-- the new buffer once it is ready.

-- Open or focus the chat, starting one if needed, or restarting an agent that
-- exited; shows a permission request again if its picker was closed without
-- an answer. Returns the chat buffer.
---@return integer?
function M.open()
    if chat and chat.dead then
        restart(chat, { agent = chat.opts.name })
    elseif not chat then
        start({})
    end
    if not chat then
        return nil
    end
    chat.view:open()
    local req = pending(chat)
    if req then
        show(chat, req)
    else
        insert(vim.api.nvim_get_current_win())
    end
    return chat.view.buf
end

-- Settings ----------------------------------------------------------------------
--
-- /model, /effort, /mode and /permissions change the setting at once, also
-- during a turn (Codex applies it from its next turn). Without such a setting,
-- the line goes to the agent's own command of that name, if it has one. An
-- agent's own /permissions always wins: Copilot's presets (allow-all, ...)
-- say more than its on/off permissions option.

local nouns =
    { model = 'model', effort = 'reasoning effort', mode = 'mode', permissions = 'permissions' }

-- The session's setting for command `name`, if it has choices.
local function setting_of(c, name)
    local s = util.find(c.client:settings(), util.categories[name])
    return s and #s.choices > 0 and s or nil
end

-- The agent's own command that handles setting command `name`, if any.
local function agent_setting(c, name)
    local cmd = c.agent_commands[name]
    if cmd and (name == 'permissions' or not setting_of(c, name)) then
        return cmd
    end
end

-- Show `/{name} {choice}` and change the setting.
local function apply(c, name, setting, choice)
    echo(c, '/' .. name .. ' ' .. util.argument(choice))
    local view = c.view
    c.client:configure(setting.id, choice.value, function(err)
        if c.closed or c.dead or c.view ~= view then
            return
        elseif err then
            report(c, err.message)
        else
            c.view:write('[Setting: ' .. name .. ' = ' .. choice.label .. ']')
        end
    end)
end

-- Set the setting of command `name` to `value`, or pick it.
local function choose_setting(name, value, now)
    local c = chat
    if not check(c, 'session') then
        return
    end
    local cmd = agent_setting(c, name)
    local s = not cmd and setting_of(c, name)
    if cmd then
        local values = not value and commands.hint_values(cmd.hint) or {}
        if #values == 0 then
            local line = '/' .. name .. (value and (' ' .. value) or '')
            submit(c, line, line, now)
            return true
        end
        local opts = { prompt = 'Boomer ' .. nouns[name] .. ':', format_item = tostring }
        pick(c, values, opts, function(choice, err)
            if err then
                report(c, err)
            elseif choice and check(c, 'session') then
                local line = '/' .. name .. ' ' .. choice
                submit(c, line, line, now)
            end
        end)
        return true
    elseif not s then
        return warn('This agent offers no ' .. nouns[name] .. ' setting', c)
    elseif value then
        local choice = util.choice(s, value)
        if not choice then
            return warn('Unknown ' .. nouns[name] .. ': ' .. value, c)
        end
        apply(c, name, s, choice)
        return true
    end
    pick(c, s.choices, {
        prompt = 'Boomer ' .. nouns[name] .. ':',
        format_item = function(item)
            return item.label .. (item.value == s.current and ' [current]' or '')
        end,
    }, function(choice, err)
        if err then
            report(c, err)
        elseif choice and check(c, 'session') then
            apply(c, name, s, choice)
        end
    end)
    return true
end

-- <S-Tab>: switch to the mode after the current one.
function next_mode()
    local c = chat
    if not check(c, 'session') then
        return
    end
    local s = setting_of(c, 'mode')
    if not s then
        return warn('This agent offers no mode setting', c)
    end
    local i = 1
    for j, choice in ipairs(s.choices) do
        if choice.value == s.current then
            i = j
        end
    end
    apply(c, 'mode', s, s.choices[i % #s.choices + 1])
end

---@param value? string Model ID or name; picks when nil.
---@param now? boolean Send an agent command at once (see submit).
function M.model(value, now)
    return choose_setting('model', value, now)
end

---@param value? string
---@param now? boolean
function M.effort(value, now)
    return choose_setting('effort', value, now)
end

-- The only way out of Copilot's plan mode: the model cannot leave it.
---@param value? string Mode ID or name; picks when nil.
---@param now? boolean
function M.mode(value, now)
    return choose_setting('mode', value, now)
end

---@param value? string
---@param now? boolean
function M.permissions(value, now)
    return choose_setting('permissions', value, now)
end

-- Sessions and agents ------------------------------------------------------------

-- Load session `id`, or pick a saved one.
---@param id? string
function M.resume(id)
    local c = chat
    if not check(c, 'switch') then
        return
    elseif not c or c.dead then
        restart(c, { agent = c and c.opts.name, pick = not id, id = id, announce = 'session' })
    elseif not id then
        choose(c, false)
    elseif id == c.session then
        already(c, '/resume ' .. id, 'Session: ' .. session_name(c))
    else
        switch(c, id, config.cwd())
    end
    return true
end

-- Start a new session with the same agent.
function M.new()
    local c = chat
    if not check(c, 'switch') then
        return
    elseif not c or c.dead then
        restart(c, { agent = c and c.opts.name, announce = 'session' })
    else
        switch(c, nil, config.cwd())
    end
    return true
end

-- Replace the chat with one for another agent profile, in the same windows,
-- or pick the agent.
---@param name? string
function M.agent(name)
    local c = chat
    if not check(c, 'switch') then
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
        already(c, '/agent ' .. name, 'Agent: ' .. name)
        return true
    end
    restart(c, { agent = name, announce = 'agent' })
    return true
end

-- Write context, token, cost and rate-limit usage into the chat. Agents with
-- rate limits are asked for fresh ones first.
function M.usage()
    local c = chat
    if not check(c, 'session') then
        return
    end
    echo(c, '/usage')
    local view = c.view
    local function write()
        if not c.closed and c.view == view then
            view:write(table.concat(status_mod.usage(c.state), '\n'))
        end
    end
    if c.client.rate_limits then
        c.client:rate_limits(write)
    else
        write()
    end
    return true
end

-- Compact the conversation natively (as a turn, so only between turns), or
-- through the agent's own command, which also takes focus instructions.
---@param focus? string
---@param now? boolean Send the agent's command at once (see submit).
function M.compact(focus, now)
    local c = chat
    if not check(c, 'session') then
        return
    elseif c.client.compact and not focus then
        if not check(c, 'idle') then
            return
        end
        echo(c, '/compact')
        turn(c, function(cb)
            c.client:compact(cb)
        end, 'compacted')
    elseif c.agent_commands.compact then
        local line = '/compact' .. (focus and (' ' .. focus) or '')
        submit(c, line, line, now)
    elseif c.client.compact then
        return warn('This agent takes no compaction instructions', c)
    else
        return warn('This agent cannot compact the conversation', c)
    end
    return true
end

-- List the commands in the chat, or open the help without one.
function M.help()
    local c = chat
    local lines =
        commands.help(commands.list(config.options.commands, c and c.agent_commands or {}))
    if c then
        echo(c, '/help')
        c.view:write(table.concat(lines, '\n'))
    elseif not pcall(vim.cmd.help, 'boomer-commands') then
        vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO, { title = 'Boomer' })
    end
    return true
end

-- Cancel the running turn; queued prompts return to the draft (like CTRL-C).
function M.cancel()
    return cancel(chat, '/cancel')
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
    return true
end

-- Lines line1..line2 of `buf` (unsaved edits included) as a fenced code block
-- headed by their location, relative to `cwd` when inside it; also returns
-- the location.
local function snippet(buf, line1, line2, cwd)
    local name = vim.api.nvim_buf_get_name(buf)
    local path = name == '' and '[No Name]' or vim.fs.relpath(cwd, name) or name
    local ref = path .. ':' .. line1 .. (line2 ~= line1 and ('-' .. line2) or '')
    local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
    local fence = '```'
    for _, l in ipairs(lines) do
        for run in l:gmatch('`+') do
            if #run >= #fence then
                fence = ('`'):rep(#run + 1)
            end
        end
    end
    local block = { ref, fence .. vim.bo[buf].filetype }
    vim.list_extend(block, lines)
    block[#block + 1] = fence
    return table.concat(block, '\n'), ref
end

-- The chat, started (or restarted) if needed and shown without leaving the
-- current window; nil if it could not start.
local function reveal()
    local win = vim.api.nvim_get_current_win()
    if chat and chat.dead then
        restart(chat, { agent = chat.opts.name })
    elseif not chat then
        start({})
    end
    if not chat then
        return nil
    end
    chat.view:open(true)
    if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
    end
    return chat
end

-- Run a line typed after :Boomer as if submitted in the chat: `/name args`
-- runs a command, `//text` sends `/text`, other text is sent as a prompt,
-- starting the chat if needed. The current window stays current. An empty
-- line opens the chat. `range` adds lines of a buffer: to the prompt, or to
-- the draft without text. A line that cannot run now only warns.
---@param line? string
---@param range? { buf: integer, line1: integer, line2: integer }
function M.run(line, range)
    line = vim.trim(line or '')
    local cmd = commands.parse(line)
    if range and cmd and cmd.name then
        return warn('A range takes a prompt, not a command', chat)
    elseif range and vim.bo[range.buf].filetype == 'boomer' then
        return warn('Select lines in another buffer', chat)
    elseif cmd and cmd.name then
        return run_command(chat, cmd.name, cmd.args)
    elseif line == '' and not range then
        return M.open() and true
    end
    local c = reveal()
    if not c then
        return
    end
    local block, ref
    if range then
        block, ref = snippet(range.buf, range.line1, range.line2, c.cwd)
    end
    if line == '' then
        local draft = c.view:draft()
        c.view:set_draft(draft:find('%S') and (draft .. '\n\n' .. block) or block)
        return M.open() and true
    end
    local text = cmd and cmd.text or line
    if not can_send(c, text) then
        return
    end
    if not block then
        submit(c, text, line)
    else
        local typed = line .. '\n\n' .. block
        submit(c, text .. '\n\n' .. block, line .. ' [' .. ref .. ']', nil, typed)
    end
    return true
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
    for _, item in ipairs(commands.list(config.options.commands, c.agent_commands)) do
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

-- Values for a command's argument: setting choices, agent names, user
-- `complete` lists, or the choices in an agent command's hint.
local function arg_candidates(name)
    local c = chat
    local item = commands.find(config.options.commands, c and c.agent_commands or {}, name)
    if not item then
        return {}
    end
    local spec = item.spec
    if item.source == 'agent' then
        return commands.hint_values(spec.hint)
    elseif item.source == 'user' then
        if type(spec.complete) == 'function' then
            local ok, list = pcall(spec.complete, c and M.status())
            return ok and type(list) == 'table' and list or {}
        end
        return spec.complete or {}
    elseif name == 'agent' then
        return config.installed_agent_names(c and c.opts.name)
    elseif not util.categories[name] or not c or c.dead or not c.client then
        return {}
    end
    local cmd = agent_setting(c, name)
    local s = not cmd and setting_of(c, name)
    if not s then
        return cmd and commands.hint_values(cmd.hint) or {}
    end
    -- Copilot's mode IDs are URIs; their names are what anyone types. It also
    -- lists some models twice.
    local out, seen = {}, {}
    for _, choice in ipairs(s.choices) do
        local value = util.argument(choice)
        if not seen[value] then
            seen[value] = true
            out[#out + 1] = value
        end
    end
    return out
end

local function prefixed(list, lead)
    return vim.tbl_filter(function(s)
        return vim.startswith(s, lead)
    end, list)
end

-- :Boomer completion: `/command` names, then their arguments. Prompt text
-- completes nothing.
function M.complete(lead, cmdline, pos)
    local before = cmdline:sub(1, pos):gsub('^%s*%S+%s*', '', 1)
    local name = before:match('^/(%S+)%s')
    if name then
        return prefixed(arg_candidates(name), lead)
    elseif before ~= '' and not before:match('^/%S*$') then
        return {}
    end
    local names = vim.tbl_map(function(item)
        return '/' .. item.name
    end, commands.list(config.options.commands, chat and chat.agent_commands or {}))
    return prefixed(names, lead)
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
