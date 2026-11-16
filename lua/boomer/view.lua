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
-- lines; extmarks in `prompt_ns` decorate the live prompt and follow it
-- (View:decorate). Nothing else tracks positions.
local api = vim.api
local ns = api.nvim_create_namespace('boomer')
local prompt_ns = api.nvim_create_namespace('boomer.prompt')

---@class boomer.View
---@field buf integer
---@field labels { user: string, agent: string }
---@field prompt string Prompt text: the user label and a space.
---@field window? table config `window` option.
---@field current? { role: string, id: string? } Message being streamed.
---@field submit? boolean The last output was a submitted draft (ends without a blank line).
---@field marks table<string, integer> Extmark IDs of the live prompt's decorations.
---@field queued string[] Queued prompts, shown as virtual lines (View:set_queued).
local View = {}
View.__index = View

-- Highlight groups, linked by default so colorschemes can override them.
local function highlights()
    for group, link in pairs({
        BoomerUserLabel = 'Title',
        BoomerAssistantLabel = 'Title',
        BoomerSystem = 'Comment',
        BoomerError = 'DiagnosticError',
        BoomerQueued = 'Comment',
        BoomerWinbar = 'WinBar',
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
-- followed by a space. opts.window: how open() shows the chat (see View:open).
---@return boomer.View
function View.new(opts)
    opts = opts or {}
    local buf = api.nvim_create_buf(false, true)
    local labels =
        vim.tbl_extend('force', { user = 'Prompt:', agent = 'Agent:' }, opts.labels or {})
    local prompt = labels.user:match('%s$') and labels.user or labels.user .. ' '
    local self = setmetatable(
        {
            buf = buf,
            labels = labels,
            prompt = prompt,
            window = opts.window,
            marks = {},
            queued = {},
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
    -- Every change may move the prompt or change the line above it. A submit
    -- moves the input mark only after this, so submitted() decorates again.
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
            vim.wo[0][0].conceallevel = 0
            if opts.winbar then
                vim.wo[0][0].winbar = opts.winbar
            end
        end,
    })
    return self
end

-- False once the buffer was unloaded; writes are then dropped.
function View:valid()
    return api.nvim_buf_is_loaded(self.buf)
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
        hl_group = 'BoomerUserLabel',
        priority = 200,
        strict = false,
    })
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

-- Append text to the output (continuing its last line) and return the range
-- it now occupies: start row/col, end row/col.
function View:append(text)
    self.submit = false
    local row, col = self:output_end()
    vim.fn.prompt_appendbuf(self.buf, vim.split(text, '\n', { plain = true }))
    local end_row, end_col = self:output_end()
    return row, col, end_row, end_col
end

-- Separator that starts a new block after exactly one blank line, given
-- what the output ends with. After a submitted draft the output ends at the
-- start of a line, so one newline makes the blank line.
function View:gap()
    if self.submit then
        return '\n'
    end
    local row = self:row()
    local lines = api.nvim_buf_get_lines(self.buf, math.max(row - 2, 0), row, false)
    if #lines == 0 then
        return ''
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

-- Called from the prompt callback after Neovim committed the input above the new prompt.
-- Also used for unsent input, which stays visible (followed by "[not sent]").
-- The committed "<prompt><text>" lines already are a user message; only the
-- label is highlighted.
function View:submitted(text)
    self.current = nil
    local first = self:row() - #vim.split(text, '\n', { plain = true })
    label(self.buf, first, #self:name('user'), 'BoomerUserLabel')
    -- The submitted line is closed: the next output starts on a new line.
    self.submit = true
    self:decorate()
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
        label(self.buf, role == 'user' and row or row - 1, #name, group)
        self.current = { role = role, id = id }
    end
    if text ~= '' then
        self:append(text)
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
        local w = vim.tbl_extend(
            'force',
            { position = 'right', width = 0.5, height = 0.5 },
            self.window or {}
        )
        open_win(self.buf, w)
        vim.wo.wrap = true
        vim.wo.number = false
        vim.wo.relativenumber = false
        local row, col = self:row()
        api.nvim_win_set_cursor(0, { row + 1, col })
    end
    vim.wo[0][0].conceallevel = 0
end

return View
