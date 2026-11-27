-- The chat buffer: a native prompt buffer ('buftype' prompt). Neovim owns
-- input protection, history-safe output insertion (prompt_appendbuf) and the
-- prompt line; treesitter renders the whole transcript as Markdown.
--
-- Layout: transcript blocks separated by one blank line, then the prompt
-- line(s) holding the draft. The ':' mark is Neovim's input mark, the start
-- of the editable draft; everything above it is output. Agent messages are
-- their label on its own line followed by the text; user messages are the
-- prompt (the user label and a space) followed by the text, as Neovim
-- commits submitted drafts. Extmarks in `ns` highlight labels, system lines
-- and diffs; extmarks in `sign_ns` span messages to show their role's sign;
-- extmarks in `prompt_ns` decorate the live prompt and follow it
-- (View:decorate); extmarks in `plain_ns` span system blocks, which are left
-- out of the Markdown parse (View:exclude_plain). Nothing else tracks positions.
local api = vim.api
local util = require('boomer.util')
local ns = api.nvim_create_namespace('boomer')
local sign_ns = api.nvim_create_namespace('boomer.sign')
local prompt_ns = api.nvim_create_namespace('boomer.prompt')
local plain_ns = api.nvim_create_namespace('boomer.plain')
-- Views with user lines to move into the draft (View:adopt_lines). They are
-- moved before the next key is handled, also within mappings and macros.
local pending = setmetatable({}, { __mode = 'k' })
vim.on_key(function()
    for view in pairs(pending) do
        -- Under textlock (such as an <expr> mapping) it is retried later.
        if not pcall(view.flush, view) then
            vim.schedule(function()
                view:flush()
            end)
        end
    end
end, api.nvim_create_namespace('boomer.adopt'))

---@class boomer.View
---@field buf integer
---@field labels { user: string, agent: string }
---@field signs? { user: string, agent: string } Gutter signs of messages; nil for none.
---@field prompt string Prompt text: the user label and a space.
---@field window? table config `window` option.
---@field current? { role: string, id: string?, sign: integer? } Message being streamed,
--- with the extmark ID of its sign.
---@field submit? boolean Neovim starts the next output on a new line (b_prompt_append_new_line):
--- set initially and after a committed draft, cleared by appending.
---@field marks table<string, integer> Extmark IDs of the live prompt's decorations.
---@field queued string[] Queued prompts, shown as virtual lines (View:set_queued).
---@field busy? boolean The agent is busy: the live prompt is grayed out (View:set_busy).
---@field cwd? string Diff paths below it are shown relative to it.
---@field diff_lines? integer Lines of a tool call's diff shown; nil for all.
---@field writing? boolean The view itself is changing the buffer (View:edit).
---@field adopt? { first: integer, last: integer, tick: integer } Rows the user inserted right
--- above the prompt, still to be moved into the draft (View:adopt_lines), and the changedtick
--- after the insertion.
---@field adopted table<integer, true> Undo sequence numbers of insertions moved into the draft.
---@field plain? boolean System blocks were written, to leave out of the Markdown parse.
---@field parser? vim.treesitter.LanguageTree Parser told to leave out system blocks.
local View = {}
View.__index = View

-- Highlight groups, defined by default so colorschemes can override them.
-- Labels are bold in their role's color; signs follow the labels.
local function highlights()
    for group, base in pairs({ BoomerUserLabel = 'Function', BoomerAssistantLabel = 'String' }) do
        local hl = api.nvim_get_hl(0, { name = base, link = false })
        hl.bold, hl.default = true, true
        if hl.cterm then
            hl.cterm.bold = true
        end
        api.nvim_set_hl(0, group, hl)
    end
    for group, link in pairs({
        BoomerUserSign = 'BoomerUserLabel',
        BoomerAssistantSign = 'BoomerAssistantLabel',
        BoomerSystem = 'Comment',
        BoomerError = 'DiagnosticError',
        BoomerWarning = 'DiagnosticWarn',
        BoomerQueued = 'Comment',
        BoomerPromptBusy = 'BoomerQueued',
        BoomerWinbar = 'WinBar',
        BoomerWinbarTitle = 'Title',
        BoomerWinbarBusy = 'DiagnosticWarn',
        BoomerWinbarError = 'DiagnosticError',
        BoomerDiffAdd = 'DiffAdd',
        BoomerDiffDelete = 'DiffDelete',
        BoomerDiffText = 'DiffText',
        BoomerDiffHunk = 'DiffChange',
    }) do
        api.nvim_set_hl(0, group, { default = true, link = link })
    end
end
highlights()
api.nvim_create_autocmd('ColorScheme', {
    group = api.nvim_create_augroup('BoomerHighlights', { clear = true }),
    callback = highlights,
})
vim.treesitter.language.register('markdown', 'boomer')

-- opts.winbar: 'winbar' value for windows showing the chat (window-local per buffer).
-- opts.labels: { user = 'Prompt:', agent = 'Agent:' }; the prompt is the user label
-- followed by a space. opts.signs: { user = '▌', agent = '▌' }, signs shown in the
-- gutter next to messages, or nil. opts.window: how open() shows the chat
-- (config `window`). opts.cwd: diff paths are shown relative to it.
-- opts.diff_lines: lines of a tool call's diff shown (config `diff_lines`).
---@return boomer.View
function View.new(opts)
    local buf = api.nvim_create_buf(false, true)
    local labels = opts.labels
    local prompt = labels.user:match('%s$') and labels.user or labels.user .. ' '
    local self = setmetatable(
        {
            buf = buf,
            labels = labels,
            signs = opts.signs,
            prompt = prompt,
            window = opts.window,
            cwd = opts.cwd,
            diff_lines = opts.diff_lines or nil,
            marks = {},
            queued = {},
            adopted = {},
            -- prompt_setprompt() below, before the input mark exists, makes
            -- Neovim start the first output on a new line.
            submit = true,
        },
        View
    )
    api.nvim_buf_set_name(buf, 'boomer://chat/' .. buf)
    vim.bo[buf].buftype = 'prompt'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'boomer'
    vim.fn.prompt_setprompt(buf, prompt)
    -- Initialize the native input mark before the buffer is first displayed.
    api.nvim_buf_set_lines(buf, 0, -1, false, { prompt })
    api.nvim_buf_set_mark(buf, ':', 1, #prompt, {})
    -- Every change may move the prompt or change the line above it.
    api.nvim_buf_attach(buf, false, {
        on_lines = function(_, _, tick, first, last, new_last)
            if not self:valid() then
                pending[self] = nil
                return true
            end
            -- Lines the user inserted right above the prompt (P, a linewise
            -- <C-R>, :put!) pushed the input mark down past them. They are
            -- moved into the draft before the next key or write, as the
            -- buffer cannot be changed from here.
            if not self.writing and last == first and self:row() == new_last then
                local adopt = self.adopt
                local from = adopt and adopt.last == first and adopt.first or first
                self.adopt = { first = from, last = new_last, tick = tick }
                pending[self] = true
                vim.schedule(function()
                    self:flush()
                end)
            end
            -- A new parser (treesitter restarted) is told on its first change.
            if
                self.plain
                and vim.treesitter.get_parser(self.buf, nil, { error = false }) ~= self.parser
            then
                self:exclude_plain()
            end
            self:decorate()
        end,
    })
    self:decorate()
    pcall(vim.treesitter.start, buf, 'markdown')
    -- Show Markdown markers literally; the transcript is also the source text.
    api.nvim_create_autocmd('BufWinEnter', {
        buffer = buf,
        callback = function()
            self:set_window_options()
            if opts.winbar then
                vim.wo[0][0].winbar = opts.winbar
            end
        end,
    })
    return self
end

-- Options of the current window, local to the chat buffer.
function View:set_window_options()
    vim.wo[0][0].conceallevel = 0
    if self.signs then
        -- The sign column shows a sign only on the first screen row of a
        -- wrapped line; the status column draws it on every row instead.
        vim.wo[0][0].signcolumn = 'no'
        vim.wo[0][0].statuscolumn = "%!v:lua.require'boomer.view'.statuscolumn()"
    end
end

-- 'statuscolumn' of chat windows: the sign of the message (or draft) on the
-- drawn line, on each of its screen rows; none on virtual lines.
function View.statuscolumn()
    local buf = api.nvim_win_get_buf(vim.g.statusline_winid)
    local row = vim.v.lnum - 1
    if vim.v.virtnum >= 0 then
        for _, n in ipairs({ sign_ns, prompt_ns }) do
            local found = api.nvim_buf_get_extmarks(buf, n, { row, 0 }, { row, -1 }, {
                details = true,
                overlap = true,
                type = 'sign',
            })
            local d = found[1] and found[1][4]
            if d then
                return ('%%#%s#%s%%*'):format(d.sign_hl_group, d.sign_text:gsub('%%', '%%%%'))
            end
        end
    end
    return '  '
end

-- False once the buffer was unloaded; writes are then dropped.
function View:valid()
    return api.nvim_buf_is_loaded(self.buf)
end

-- Whether the chat is shown in some window.
function View:visible()
    return self:valid() and #vim.fn.win_findbuf(self.buf) > 0
end

-- Position of the input mark (start of the editable prompt).
function View:row()
    local pos = api.nvim_buf_get_mark(self.buf, ':')
    return pos[1] - 1, pos[2]
end

-- The text being typed (all prompt lines).
function View:draft()
    self:flush()
    return vim.fn.prompt_getinput(self.buf)
end

-- Move lines the user inserted right above the prompt (self.adopt, rows
-- first..last-1) into the start of the draft, where they were meant to go:
-- the prompt moves up to their first line. Joined to the insertion's undo
-- step if nothing changed since; a redo of such a step (self.adopted) puts
-- the text back as it was, so only the input mark moves. They stay pending
-- if the buffer cannot be changed now (textlock).
function View:adopt_lines()
    local adopt = self.adopt
    local first, last = adopt.first, adopt.last
    if self:row() == last then
        local prompt = self.prompt
        local function seq()
            return vim.fn.undotree(self.buf).seq_cur
        end
        if not self.adopted[seq()] then
            local cursors = {}
            for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
                cursors[win] = api.nvim_win_get_cursor(win)
            end
            local joined = api.nvim_buf_get_changedtick(self.buf) == adopt.tick
                and api.nvim_buf_call(self.buf, function()
                    return pcall(vim.cmd.undojoin)
                end)
            local line = api.nvim_buf_get_lines(self.buf, last, last + 1, false)[1]
            local strip = line:sub(1, #prompt) == prompt
            if strip then
                api.nvim_buf_set_text(self.buf, last, 0, last, #prompt, {})
            end
            api.nvim_buf_set_text(self.buf, first, 0, first, 0, { prompt })
            if joined then
                self.adopted[seq()] = true
            end
            for win, pos in pairs(cursors) do
                if pos[1] == first + 1 then
                    pos[2] = pos[2] + #prompt
                elseif pos[1] == last + 1 and strip then
                    pos[2] = math.max(pos[2] - #prompt, 0)
                end
                api.nvim_win_set_cursor(win, pos)
            end
        end
        api.nvim_buf_set_mark(self.buf, ':', first + 1, #prompt, {})
    end
    self.adopt = nil
    pending[self] = nil
    self:decorate()
end

-- Move pending user insertions above the prompt into the draft. Output
-- positions are read through this, so nothing is written below them.
function View:flush()
    if not self:valid() then
        pending[self] = nil
    elseif self.adopt then
        self:edit(function() end)
    end
end

-- Change the buffer with `fn`: user insertions above the prompt are first
-- moved into the draft, and the change is not mistaken for one of them.
function View:edit(fn)
    if not self:valid() then
        return
    end
    local writing = self.writing
    self.writing = true
    local ok, err = pcall(function()
        if self.adopt then
            self:adopt_lines()
        end
        fn()
    end)
    self.writing = writing
    if not ok then
        error(err, 0)
    end
end

-- Replace the draft, keeping the input mark. A cursor in the draft moves to
-- its end.
function View:set_draft(text)
    if not self:valid() then
        return
    end
    local row
    local lines = vim.split(text, '\n', { plain = true })
    lines[1] = self.prompt .. lines[1]
    self:edit(function()
        row = self:row()
        api.nvim_buf_set_lines(self.buf, row, -1, false, lines)
        api.nvim_buf_set_mark(self.buf, ':', row + 1, #self.prompt, {})
    end)
    for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
        if api.nvim_win_get_cursor(win)[1] > row then
            api.nvim_win_set_cursor(win, { row + #lines, #lines[#lines] })
        end
    end
end

-- Show queued prompts (their text as typed) next to the live prompt.
function View:set_queued(list)
    self.queued = list
    if self:valid() then
        self:decorate()
    end
end

-- Gray out the live prompt's label, sign and draft while the agent is busy.
function View:set_busy(busy)
    if self.busy == busy then
        return
    end
    self.busy = busy
    if self:valid() then
        self:decorate()
    end
end

-- Set or move (or, without opts, delete) the live prompt's decoration `key`.
function View:mark(key, row, col, opts)
    if opts then
        opts.id = self.marks[key]
        self.marks[key] = api.nvim_buf_set_extmark(self.buf, prompt_ns, row, col, opts)
    elseif self.marks[key] then
        api.nvim_buf_del_extmark(self.buf, prompt_ns, self.marks[key])
        self.marks[key] = nil
    end
end

-- Highlight the live prompt's label like the transcript's user labels (and
-- gray out the label, sign and draft while busy), and
-- keep one blank line above the prompt: a virtual one when the output does
-- not end with a blank line (streamed text continues its last line). Queued
-- prompts are virtual lines between that blank line and the prompt, set off
-- from the prompt by another blank line. Virtual
-- lines cannot be ephemeral (decoration provider), so the marks are moved
-- after every change instead.
function View:decorate()
    local row, col = self:row()
    self:mark('label', row, 0, {
        end_col = #self:name('user'),
        hl_group = self.busy and 'BoomerPromptBusy' or 'BoomerUserLabel',
        priority = 200,
        strict = false,
    })
    if self.signs then
        self:mark('sign', row, 0, {
            end_row = api.nvim_buf_line_count(self.buf) - 1,
            sign_text = self.signs.user,
            sign_hl_group = self.busy and 'BoomerPromptBusy' or 'BoomerUserSign',
        })
    end
    if self.busy then
        local last = api.nvim_buf_line_count(self.buf) - 1
        self:mark('draft', row, col, {
            end_row = last,
            end_col = #api.nvim_buf_get_lines(self.buf, last, last + 1, false)[1],
            hl_group = 'BoomerPromptBusy',
            priority = 200,
            strict = false,
        })
    else
        self:mark('draft')
    end
    local lines = {}
    for _, text in ipairs(self.queued) do
        local first = text:match('^[^\n]*')
        local more = select(2, text:gsub('\n', ''))
        local suffix = more > 0 and (' (+%d %s)'):format(more, more == 1 and 'line' or 'lines')
        lines[#lines + 1] = { { 'Queued: ' .. first .. (suffix or ''), 'BoomerQueued' } }
    end
    -- Lines above the first one are hidden (without scrolling), so with an
    -- empty transcript the queue is shown below the draft.
    if row == 0 then
        self:mark('blank')
        if #lines == 0 then
            return self:mark('queue')
        end
        table.insert(lines, 1, {})
        return self:mark('queue', api.nvim_buf_line_count(self.buf) - 1, 0, { virt_lines = lines })
    end
    self:mark('queue')
    if #lines > 0 then
        lines[#lines + 1] = {}
    end
    if api.nvim_buf_get_lines(self.buf, row - 1, row, false)[1] ~= '' then
        table.insert(lines, 1, {})
    end
    if #lines == 0 then
        return self:mark('blank')
    end
    self:mark('blank', row, 0, { virt_lines = lines, virt_lines_above = true })
end

-- End of the output region; prompt_appendbuf continues this line.
function View:output_end()
    self:flush()
    local row = self:row() - 1
    if row < 0 then
        return 0, 0
    end
    return row, #api.nvim_buf_get_lines(self.buf, row, row + 1, false)[1]
end

-- Append text to the output (continuing its last line, or on a new line
-- after a submitted draft) and return the range it now occupies: start
-- row/col, end row/col.
function View:append(text)
    self.submit = false
    local row, col = self:output_end()
    -- Continuing a line rewrites it, which collapses the highlights on it
    -- (such as a user label); they are put back on the unchanged prefix.
    local marks = col > 0
            and api.nvim_buf_get_extmarks(self.buf, ns, { row, 0 }, { row, -1 }, { details = true })
        or {}
    self:edit(function()
        vim.fn.prompt_appendbuf(self.buf, vim.split(text, '\n', { plain = true }))
    end)
    for _, m in ipairs(marks) do
        local d = m[4]
        if d.end_row == row then
            api.nvim_buf_set_extmark(self.buf, ns, row, m[3], {
                id = m[1],
                end_row = row,
                end_col = d.end_col,
                hl_group = d.hl_group,
                priority = d.priority,
                strict = false,
            })
        end
    end
    local end_row, end_col = self:output_end()
    return row, col, end_row, end_col
end

-- Separator that starts a new block after exactly one blank line, given
-- what the output ends with and whether Neovim starts it on a new line.
function View:gap()
    self:flush()
    local row = self:row()
    local lines = api.nvim_buf_get_lines(self.buf, math.max(row - 2, 0), row, false)
    if #lines == 0 then
        return ''
    elseif self.submit then
        return lines[#lines] == '' and '' or '\n'
    elseif lines[#lines] ~= '' then
        return '\n\n'
    end
    return #lines == 2 and lines[1] ~= '' and '\n' or ''
end

-- End the streamed message, if any, and start a new block after the output.
function View:open_block()
    self.current = nil
    local gap = self:gap()
    if gap ~= '' then
        self:append(gap)
    end
end

-- Write a block of (possibly multiline) text on its own lines, highlighted
-- with `group` (default BoomerSystem). Ends the streamed message, if any.
function View:write(text, group)
    if self:valid() then
        self:open_block()
        local row, col, end_row, end_col = self:append(text .. '\n')
        api.nvim_buf_set_extmark(self.buf, ns, row, col, {
            end_row = end_row,
            end_col = end_col,
            hl_group = group or 'BoomerSystem',
            priority = 150,
        })
        -- The text ends before the empty row the output continues on. Text
        -- replaced at either edge (or restored by undo) stays in the block.
        local last = end_row - 1
        api.nvim_buf_set_extmark(self.buf, plain_ns, last - select(2, text:gsub('\n', '')), 0, {
            end_row = last,
            end_col = #api.nvim_buf_get_lines(self.buf, last, last + 1, false)[1],
            right_gravity = false,
            end_right_gravity = true,
        })
        self.plain = true
        self:exclude_plain()
    end
end

-- Leave system blocks out of the Markdown parse: they are not Markdown, and
-- one could open a block that never closes (such as a code fence in a tool's
-- command), turning the rest of the transcript into code. The parse covers
-- the text between them and after the last one. Each range starts at the
-- end of a block's last line rather than on the next row, so that output
-- appended on that row is never left out with the block.
-- An edit before the next parse restores the regions of the last parse (or
-- drops them, if it was invalidated), and undo restores extmarks after all
-- change callbacks; so the regions are set again right before every parse,
-- once edits have settled. This wraps the parser's internal `_parse`, which
-- an async parse also restarts with after an edit. Parsing at once instead
-- would process injections in the whole transcript.
function View:exclude_plain()
    local parser = vim.treesitter.get_parser(self.buf, nil, { error = false })
    if not parser then
        return
    end
    local parse = parser._parse
    -- `_parse` is private: without it, regions are only set on changes.
    if self.parser ~= parser and type(parse) == 'function' then
        self.parser = parser
        parser._parse = function(tree, range, ...)
            if self.parser == parser and self:valid() then
                self:exclude_plain()
                -- Without a range, only a tree covering the whole buffer is
                -- parsed; a range in the regions also parses ours.
                if not range then
                    local first = parser:included_regions()[1][1]
                    range = { first[1], first[2], first[1] + 1, 0 }
                end
            end
            return parse(tree, range, ...)
        end
    end
    local function byte(row, col)
        return api.nvim_buf_get_offset(self.buf, row) + col
    end
    local function before(r1, c1, r2, c2)
        return r1 < r2 or r1 == r2 and c1 < c2
    end
    local ranges, row, col = {}, 0, 0
    for _, m in ipairs(api.nvim_buf_get_extmarks(self.buf, plain_ns, 0, -1, { details = true })) do
        local d = m[4]
        -- Blocks whose text was deleted or replaced collapse or invert.
        if before(m[2], m[3], d.end_row, d.end_col) then
            if before(row, col, m[2], m[3]) then
                ranges[#ranges + 1] = { row, col, byte(row, col), m[2], m[3], byte(m[2], m[3]) }
            end
            if before(row, col, d.end_row, d.end_col) then
                row, col = d.end_row, d.end_col
            end
        end
    end
    -- An end past any edit keeps the last range open to text appended later.
    local open = 0xFFFFFFFF
    ranges[#ranges + 1] = { row, col, byte(row, col), open, open, open }
    if not vim.deep_equal(parser:included_regions(), { ranges }) then
        parser:set_included_regions({ ranges })
    end
end

local function continuation(byte)
    return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

-- Byte columns [first, a_end) of `a` and [first, b_end) of `b` that differ
-- between their common prefix and suffix, on character boundaries.
local function changed(a, b)
    local n = math.min(#a, #b)
    local first = 0
    while first < n and a:byte(first + 1) == b:byte(first + 1) do
        first = first + 1
    end
    while first > 0 and (continuation(a:byte(first + 1)) or continuation(b:byte(first + 1))) do
        first = first - 1
    end
    local last = 0
    while last < n - first and a:byte(#a - last) == b:byte(#b - last) do
        last = last + 1
    end
    while
        last > 0
        and (continuation(a:byte(#a - last + 1)) or continuation(b:byte(#b - last + 1)))
    do
        last = last - 1
    end
    return first, #a - last, #b - last
end

local line_kinds = { ['@'] = 'hunk', ['+'] = 'add', ['-'] = 'delete', ['\\'] = 'note' }

-- Lines of a diff block, { text, kind }: file headers and hunks, cut off
-- after `limit` lines (nil for none).
local function block_lines(self, diffs, limit)
    local out = {}
    local function header(prefix, p)
        p = p and self.cwd and vim.fs.relpath(self.cwd, p) or p
        out[#out + 1] = { prefix .. (p or '/dev/null'), 'header' }
    end
    for _, d in ipairs(diffs) do
        header('--- ', d.from)
        header('+++ ', d.to)
        for line in d.text:gmatch('[^\n]*\n?') do
            if line ~= '' then
                line = line:gsub('\n$', '')
                out[#out + 1] = { line, line_kinds[line:sub(1, 1)] or 'context' }
            end
        end
    end
    local hidden = limit and #out - limit or 0
    if hidden > 0 then
        out = vim.list_slice(out, 1, limit)
        out[#out + 1] =
            { ('... %d more %s'):format(hidden, hidden == 1 and 'line' or 'lines'), 'note' }
    end
    return out
end

local diff_groups = {
    fence = 'BoomerSystem',
    header = 'BoomerSystem',
    note = 'BoomerSystem',
    hunk = 'BoomerDiffHunk',
    add = 'BoomerDiffAdd',
    delete = 'BoomerDiffDelete',
}

-- Write file changes as a fenced Markdown `diff` block, highlighted like
-- diff mode: added and deleted lines over the whole width, and the changed
-- part of each deleted line followed by an added one. Ends the streamed
-- message, if any.
---@param diffs boomer.Diff[]
function View:diff(diffs)
    if not self:valid() then
        return
    end
    local lines = block_lines(self, diffs, self.diff_lines)
    local function texts()
        return vim.tbl_map(function(l)
            return l[1]
        end, lines)
    end
    local fence = util.fence(texts())
    table.insert(lines, 1, { fence .. 'diff', 'fence' })
    lines[#lines + 1] = { fence, 'fence' }
    self:open_block()
    local row, col = self:append(table.concat(texts(), '\n') .. '\n')
    local function mark(i, start, stop, opts)
        opts.end_row, opts.end_col = row + i - 1, (i == 1 and col or 0) + stop
        api.nvim_buf_set_extmark(self.buf, ns, row + i - 1, (i == 1 and col or 0) + start, opts)
    end
    for i, l in ipairs(lines) do
        local kind, group = l[2], diff_groups[l[2]]
        if kind == 'add' or kind == 'delete' then
            mark(i, 0, 0, { line_hl_group = group, priority = 150 })
        elseif group then
            mark(i, 0, #l[1], { hl_group = group, priority = 150 })
        end
    end
    -- Pair each run of deleted lines with the run of added lines after it;
    -- "\ No newline at end of file" notes may come between them.
    local i = 1
    while i <= #lines do
        local dels, adds = {}, {}
        while lines[i] and (lines[i][2] == 'delete' or #dels > 0 and lines[i][2] == 'note') do
            dels[#dels + 1] = lines[i][2] == 'delete' and i or nil
            i = i + 1
        end
        while #dels > 0 and lines[i] and lines[i][2] == 'add' do
            adds[#adds + 1] = i
            i = i + 1
        end
        for k = 1, math.min(#dels, #adds) do
            local a, b = lines[dels[k]][1]:sub(2), lines[adds[k]][1]:sub(2)
            local first, a_end, b_end = changed(a, b)
            for _, m in ipairs({ { dels[k], a_end }, { adds[k], b_end } }) do
                if m[2] > first then
                    mark(m[1], first + 1, m[2] + 1, { hl_group = 'BoomerDiffText', priority = 200 })
                end
            end
        end
        if #dels == 0 then
            i = i + 1
        end
    end
end

-- Highlight the label at the start of `row` (the first `col` bytes).
local function label(buf, row, col, group)
    api.nvim_buf_set_extmark(buf, ns, row, 0, {
        end_col = col,
        hl_group = group,
        priority = 200,
        strict = false,
    })
end

-- Label of a role's messages, without trailing space.
function View:name(role)
    return ((self.labels[role] or role):gsub('%s+$', ''))
end

-- Remove a draft Neovim committed into the output from the prompt callback
-- (keys such as <C-j> bypass the <CR> mapping), so it can be submitted like
-- any other. Neovim starts the next output on a new line once the callback
-- returns; nothing may be written before then.
function View:uncommit(text)
    local n = #vim.split(text, '\n', { plain = true })
    self:edit(function()
        local row = self:row()
        api.nvim_buf_set_lines(self.buf, math.max(row - n, 0), row, false, {})
    end)
    self.submit = true
end

-- Show the role's sign on the rows from `row` to the end of the output,
-- except a trailing empty row; `id` is the extmark to move, if any.
function View:sign(role, row, id)
    local end_row, end_col = self:output_end()
    if end_col == 0 and end_row > row then
        end_row = end_row - 1
    end
    local user = role == 'user'
    return api.nvim_buf_set_extmark(self.buf, sign_ns, row, 0, {
        id = id,
        end_row = end_row,
        sign_text = user and self.signs.user or self.signs.agent,
        sign_hl_group = user and 'BoomerUserSign' or 'BoomerAssistantSign',
    })
end

-- Stream text into the current message, starting a new labelled block when
-- the role ('user' or 'agent') or message ID changes. User text follows the
-- prompt on the label's line, as in a submitted draft.
function View:message(role, text, id)
    if not self:valid() then
        return
    end
    local m = self.current
    if not m or m.role ~= role or id and m.id ~= id then
        local name = self:name(role)
        local head = role == 'user' and self.prompt or name .. '\n'
        local _, _, row = self:append(self:gap() .. head)
        -- The user label is on the last row appended, the agent's above it.
        local group = role == 'user' and 'BoomerUserLabel' or 'BoomerAssistantLabel'
        local start = role == 'user' and row or row - 1
        label(self.buf, start, #name, group)
        m = { role = role, id = id }
        m.sign = self.signs and self:sign(role, start)
        self.current = m
    end
    if text ~= '' then
        self:append(text)
        if m.sign then
            local start = api.nvim_buf_get_extmark_by_id(self.buf, sign_ns, m.sign, {})[1]
            self:sign(role, start, m.sign)
        end
    end
end

-- Window sizes: a fraction of the editor below 1, else a count of cells.
local function cells(v, total)
    if v < 1 then
        return math.max(1, math.floor(total * v + 0.5))
    end
    return math.max(1, math.min(math.floor(v), total))
end

local function float_config(w)
    local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
    local width, height = cells(w.width, cols), cells(w.height, rows)
    -- Center the window including its border.
    return vim.tbl_extend('force', {
        relative = 'editor',
        width = width,
        height = height,
        row = math.max(0, math.floor((rows - height - 2) / 2)),
        col = math.max(0, math.floor((cols - width - 2) / 2)),
    }, w.float or {})
end

-- Floats opened by Boomer, with their window options, re-laid out on resize.
local floats = {}
api.nvim_create_autocmd('VimResized', {
    group = api.nvim_create_augroup('BoomerView', { clear = true }),
    callback = function()
        for win, w in pairs(floats) do
            if api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative ~= '' then
                api.nvim_win_set_config(win, float_config(w))
            else
                floats[win] = nil
            end
        end
    end,
})

local splits = { left = 'left', right = 'right', top = 'above', bottom = 'below' }

-- Open an editor-wide split or a centered float showing buf; returns the window.
local function open_win(buf, w)
    if w.position == 'float' then
        local win = api.nvim_open_win(buf, true, float_config(w))
        floats[win] = w
        return win
    end
    local cfg = { split = splits[w.position], win = -1 }
    if w.position == 'left' or w.position == 'right' then
        cfg.width = cells(w.width, vim.o.columns)
    else
        cfg.height = cells(w.height, vim.o.lines - vim.o.cmdheight)
    end
    return api.nvim_open_win(buf, true, cfg)
end

-- Focus a window showing the chat, or open one as configured by
-- window = { position, width, height, float } (see boomer-config). `here`:
-- only reuse a window in the current tab page.
function View:open(here)
    local win = vim.iter(vim.fn.win_findbuf(self.buf)):find(function(w)
        return not here or api.nvim_win_get_tabpage(w) == api.nvim_get_current_tabpage()
    end)
    if win then
        api.nvim_set_current_win(win)
    else
        open_win(self.buf, self.window)
        vim.wo.wrap = true
        vim.wo.number = false
        vim.wo.relativenumber = false
        local row, col = self:row()
        api.nvim_win_set_cursor(0, { row + 1, col })
    end
    self:set_window_options()
end

return View
