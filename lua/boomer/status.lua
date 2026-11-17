-- Chat status: one plain table per chat (see :help boomer.status()), rendered
-- for the winbar, statuslines and /usage, and announced with a coalesced
-- `User BoomerStatus` autocmd.

---@class boomer.Status
---@field agent string Profile name.
---@field protocol 'codex'|'acp'
---@field state string starting, loading, ready, running, cancelling, failed, closed or no session.
---@field queued? integer Prompts waiting to be sent.
---@field cwd string
---@field session? string
---@field title? string
---@field model? string
---@field effort? string
---@field mode? string
---@field permissions? string Permission preset label (Codex).
---@field context? { used: number?, size: number? } Tokens in the context window.
---@field tokens? { total: number?, input: number?, output: number? }
---@field cost? { amount: number?, currency: string? }
---@field limits? boomer.Limits Account rate limits (Codex).
---@field buf? integer Chat buffer (in copies handed out by boomer.status()).

---@class boomer.Limit
---@field used number Percent of the window used.
---@field window? number Window length in minutes.
---@field resets? number Unix time the window resets.

---@class boomer.Limits
---@field primary? boomer.Limit Short window (5 hours).
---@field secondary? boomer.Limit Long window (weekly).

local util = require('boomer.util')
local M = {}

local busy = { starting = true, loading = true, running = true, cancelling = true }
local bad = { failed = true, closed = true }

local function context(ctx)
    if not ctx or type(ctx.used) ~= 'number' then
        return nil
    end
    local pct = util.percent(ctx)
    return pct and ('ctx %d%%'):format(pct) or ('ctx ' .. util.tokens(ctx.used))
end

local function cost(c)
    if c and type(c.amount) == 'number' then
        return ('%.2f %s'):format(c.amount, c.currency or '')
    end
end

-- Rate-limit window name from its length, e.g. '5h' or 'Weekly'; Codex's
-- primary and secondary windows are 5 hours and a week if it is unknown.
local function window(l, key)
    local mins = l.window
    if type(mins) ~= 'number' then
        return key == 'primary' and '5h' or 'Weekly'
    end
    return mins == 10080 and 'Weekly'
        or mins % 1440 == 0 and (mins / 1440 .. 'd')
        or mins % 60 == 0 and (mins / 60 .. 'h')
        or (mins .. 'm')
end

local function used(l)
    return math.floor(l.used + 0.5)
end

-- Winbar segment for a rate limit, e.g. "5h 42%" or "wk 10%".
local function limit_part(limits, key)
    local l = limits and limits[key]
    if type(l) ~= 'table' or type(l.used) ~= 'number' then
        return {}
    end
    local name = window(l, key)
    return {
        ('%s %d%%'):format(name == 'Weekly' and 'wk' or name, used(l)),
        used(l) >= 90 and 'BoomerWinbarError' or nil,
    }
end

-- { text, highlight group } segments: agent, model (effort), mode,
-- state, queued prompts, context, cost and rate limits. Missing values are
-- skipped.
---@param st boomer.Status
---@return { [1]: string, [2]: string? }[]
function M.parts(st)
    local model = st.model
    if st.effort then
        model = model and (model .. ' (' .. st.effort .. ')') or st.effort
    end
    local state_hl = busy[st.state] and 'BoomerWinbarBusy' or bad[st.state] and 'BoomerWinbarError'
    local parts = {}
    for _, p in ipairs({
        { st.agent },
        { model },
        { st.mode },
        { st.state, state_hl or nil },
        { st.queued and (st.queued .. ' queued'), 'BoomerWinbarBusy' },
        { context(st.context) },
        { cost(st.cost) },
        limit_part(st.limits, 'primary'),
        limit_part(st.limits, 'secondary'),
    }) do
        if p[1] and p[1] ~= '' then
            parts[#parts + 1] = p
        end
    end
    return parts
end

local sep = ' | '

local function escape(s)
    return (tostring(s):gsub('%%', '%%%%'))
end

-- Plain text, e.g. "codex | gpt-5 (high) | running | ctx 42%".
---@param st boomer.Status
function M.text(st)
    return table.concat(
        vim.tbl_map(function(p)
            return p[1]
        end, M.parts(st)),
        sep
    )
end

-- The same in 'winbar' syntax with highlight groups: a "Boomer" title on the
-- left, the status right-aligned and truncated from its left when narrow.
---@param st boomer.Status
function M.winbar(st)
    local out = {}
    for _, p in ipairs(M.parts(st)) do
        local text = escape(p[1])
        out[#out + 1] = p[2] and ('%#' .. p[2] .. '#' .. text .. '%#BoomerWinbar#') or text
    end
    return '%#BoomerWinbarTitle#Boomer%#BoomerWinbar# %<%=' .. table.concat(out, sep)
end

-- The plain text, escaped for 'statusline'.
---@param st boomer.Status
function M.statusline(st)
    return escape(M.text(st))
end

-- "5h limit: 42% used (resets 14:05)"; the date is added unless it resets
-- within a day.
local function limit_line(l, key)
    local s = ('%s limit: %d%% used'):format(window(l, key), used(l))
    if type(l.resets) == 'number' then
        local soon = l.resets - os.time() < 86400
        s = s .. ' (resets ' .. os.date(soon and '%H:%M' or '%b %d %H:%M', l.resets) .. ')'
    end
    return s
end

-- Lines written by /usage.
---@param st boomer.Status
---@return string[]
function M.usage(st)
    local lines = { 'Usage | ' .. st.agent .. (st.model and (' | ' .. st.model) or '') }
    local ctx = st.context
    if ctx and type(ctx.used) == 'number' then
        local pct = util.percent(ctx)
        lines[#lines + 1] = 'Context: '
            .. util.tokens(ctx.used)
            .. (pct and (' of ' .. util.tokens(ctx.size)) or '')
            .. ' tokens'
            .. (pct and (' (%d%%)'):format(pct) or '')
    end
    local t = st.tokens
    if t and type(t.total) == 'number' then
        -- Codex reports session totals, ACP agents the last turn.
        lines[#lines + 1] = (st.protocol == 'acp' and 'Last turn: ' or 'Tokens: ')
            .. util.tokens(t.total)
            .. (
                t.input
                    and (' (%s in, %s out)'):format(util.tokens(t.input), util.tokens(t.output))
                or ''
            )
    end
    if cost(st.cost) then
        lines[#lines + 1] = 'Cost: ' .. cost(st.cost)
    end
    for _, key in ipairs({ 'primary', 'secondary' }) do
        local l = st.limits and st.limits[key]
        if type(l) == 'table' and type(l.used) == 'number' then
            lines[#lines + 1] = limit_line(l, key)
        end
    end
    if #lines == 1 then
        lines[2] = 'No usage reported yet'
    end
    return lines
end

-- Redraw and announce a changed status once per event-loop tick, outside the
-- adapter callback that changed it. `c` is the chat (boomer.init).
function M.changed(c)
    if c.status_pending then
        return
    end
    c.status_pending = true
    vim.schedule(function()
        c.status_pending = false
        pcall(vim.cmd.redrawstatus, { bang = true })
        local data = vim.deepcopy(c.state)
        data.buf = c.view.buf
        vim.api.nvim_exec_autocmds(
            'User',
            { pattern = 'BoomerStatus', modeline = false, data = data }
        )
    end)
end

return M
