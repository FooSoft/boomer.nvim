-- The chat buffer: a native prompt buffer ('buftype' prompt). Neovim owns
-- input protection, history-safe output insertion (prompt_appendbuf) and the
-- prompt line; treesitter renders the whole transcript as Markdown.
--
-- Layout: transcript blocks separated by one blank line, then the prompt
-- line(s) holding the draft. The ':' mark is Neovim's input mark, the start
-- of the editable draft; everything above it is output. Agent messages are
-- their label on its own line followed by the text; user messages are the
-- prompt (the user label and a space) followed by the text, as Neovim
-- commits submitted drafts. Extmarks in `ns` highlight labels and system
-- lines; extmarks in `sign_ns` span messages to show their role's sign;
-- extmarks in `prompt_ns` decorate the live prompt and follow it
-- (View:decorate). Nothing else tracks positions.
local api = vim.api
local ns = api.nvim_create_namespace('boomer')
local sign_ns = api.nvim_create_namespace('boomer.sign')
local prompt_ns = api.nvim_create_namespace('boomer.prompt')

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
-- (config `window`).
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
            marks = {},
            queued = {},
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
        on_lines = function()
            if not self:valid() then
                return true
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
    return vim.fn.prompt_getinput(self.buf)
end

-- Replace the draft, keeping the input mark. A cursor in the draft moves to
-- its end.
function View:set_draft(text)
    if not self:valid() then
        return
    end
    local row = self:row()
    local lines = vim.split(text, '\n', { plain = true })
    lines[1] = self.prompt .. lines[1]
    api.nvim_buf_set_lines(self.buf, row, -1, false, lines)
    api.nvim_buf_set_mark(self.buf, ':', row + 1, #self.prompt, {})
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

-- Gray out the live prompt's label and sign while the agent is busy.
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

-- Highlight the live prompt's label like the transcript's user labels, and
-- keep one blank line above the prompt: a virtual one when the output does
-- not end with a blank line (streamed text continues its last line). Queued
-- prompts are virtual lines between that blank line and the prompt. Virtual
-- lines cannot be ephemeral (decoration provider), so the marks are moved
-- after every change instead.
function View:decorate()
    local row = self:row()
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
        return self:mark('queue', api.nvim_buf_line_count(self.buf) - 1, 0, { virt_lines = lines })
    end
    self:mark('queue')
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
    vim.fn.prompt_appendbuf(self.buf, vim.split(text, '\n', { plain = true }))
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

-- Write a block of (possibly multiline) text on its own lines, highlighted
-- with `group` (default BoomerSystem). Ends the streamed message, if any.
function View:write(text, group)
    if self:valid() then
        self.current = nil
        local gap = self:gap()
        if gap ~= '' then
            self:append(gap)
        end
        local row, col, end_row, end_col = self:append(text .. '\n')
        api.nvim_buf_set_extmark(self.buf, ns, row, col, {
            end_row = end_row,
            end_col = end_col,
            hl_group = group or 'BoomerSystem',
            priority = 150,
        })
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
    local row = self:row()
    local n = #vim.split(text, '\n', { plain = true })
    api.nvim_buf_set_lines(self.buf, math.max(row - n, 0), row, false, {})
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
-- window = { position, width, height, float } (see boomer-config).
function View:open()
    local win = vim.fn.win_findbuf(self.buf)[1]
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
