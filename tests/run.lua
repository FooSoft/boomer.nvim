-- nvim --clean --headless -l tests/run.lua [name-filter]
--
-- Drives the real plugin against tests/support/fake, which plays a scenario
-- from tests/scenarios over stdio.
local root = vim.fn.fnamemodify(arg[0], ':p:h:h')
vim.opt.runtimepath:prepend(root)
-- doc/tags is not committed; plugin managers generate it, and so do tests.
vim.cmd.helptags(vim.fn.fnameescape(root .. '/doc'))
vim.cmd.runtime('plugin/boomer.lua')
local api = vim.api
local boomer = require('boomer')
local Rpc = require('boomer.rpc')
local filter = arg[1]
vim.o.showmode = false
vim.opt.shortmess:append('c')
vim.env.BOOMER_NVIM = vim.v.progpath
Rpc.term_ms, Rpc.kill_ms = 100, 300
local windows = vim.fn.has('win32') == 1
local fake = root .. '/tests/support/fake' .. (windows and '.cmd' or '')
-- Agents run in Neovim's working directory. Scenarios spell it "/tmp"; load()
-- replaces that with the directory as the plugin sends it.
vim.fn.chdir(windows and vim.uv.os_tmpdir() or '/tmp')
local cwd = require('boomer.config').resolve().cwd
-- Only the fake codex and copilot are installed; other built-in profiles are
-- made missing so the agent picker does not depend on the machine.
local absent = {}
for name in pairs(require('boomer.config').options.agents) do
    if name ~= 'codex' and name ~= 'copilot' then
        absent[name] = { command = '/missing-boomer-' .. name }
    end
end

local notices, progress, last = {}, {}, nil
vim.notify = function(msg)
    notices[#notices + 1] = msg
end
-- Progress messages would print to stdout in headless mode.
api.nvim_echo = function(chunks, _, opts)
    progress[#progress + 1] = { status = opts.status, msg = chunks[1][1] }
    return #progress
end
local start = Rpc.start
Rpc.start = function(opts)
    local rpc, err = start(opts)
    last = rpc
    return rpc, err
end

local function await(predicate, label)
    if not vim.wait(5000, predicate, 5) then
        error(
            'timeout: '
                .. label
                .. (last and last.stderr ~= '' and '\nagent stderr:\n' .. last.stderr or ''),
            2
        )
    end
end

local function pause(ms)
    vim.wait(ms, function()
        return false
    end)
end

local function load(name)
    local f = assert(io.open(root .. '/tests/scenarios/' .. name .. '.json'))
    local scenario = vim.json.decode((f:read('*a'):gsub('"/tmp"', function()
        return vim.json.encode(cwd)
    end)))
    f:close()
    return scenario
end

-- Concatenate scenario steps: steps(a, 1, 3, b, 4) = a[1..3] .. b[4..].
local function steps(...)
    local out, args = {}, { ... }
    for i = 1, select('#', ...), 3 do
        local s = args[i].steps
        for j = args[i + 1], args[i + 2] or #s do
            out[#out + 1] = vim.deepcopy(s[j])
        end
    end
    return out
end

-- The next agent process plays this scenario.
local function stage(scenario)
    local path = vim.fn.tempname() .. '.json'
    local f = assert(io.open(path, 'w'))
    f:write(vim.json.encode(scenario))
    f:close()
    vim.env.BOOMER_SCENARIO = path
end

-- extra: setup options merged over the fake-agent defaults.
local function play(scenario, backend, extra)
    stage(scenario)
    boomer.setup(vim.tbl_deep_extend('force', {
        agent = backend or 'codex',
        agents = vim.tbl_extend('force', absent, {
            codex = { command = fake },
            copilot = { command = fake },
        }),
    }, extra or {}))
end

local function open(scenario, backend, extra)
    play(scenario, backend, extra)
    return boomer.open()
end

local function text(buf)
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

local function has(buf, needle)
    return text(buf):find(needle, 1, true) ~= nil
end

local function count(buf, needle)
    local n, pos = 0, 1
    local t = text(buf)
    while true do
        local s, e = t:find(needle, pos, true)
        if not s then
            return n
        end
        n, pos = n + 1, e + 1
    end
end

-- The chat status if `buf` is the chat buffer, else an empty table.
local function state(buf)
    local st = boomer.status()
    return st and st.buf == buf and st or {}
end

local function status(buf, expected)
    return state(buf).state == expected
end

local function ready(buf)
    await(function()
        return status(buf, 'ready')
    end, 'ready; transcript:\n' .. text(buf))
end

local function draft(buf)
    return vim.fn.prompt_getinput(buf)
end

-- flags '!': stay in Insert mode.
local function keys(s, flags)
    api.nvim_feedkeys(
        api.nvim_replace_termcodes(s, true, false, true),
        'xt' .. (flags or ''),
        false
    )
end

-- Replace the draft as if typed, keeping Neovim's input mark in place.
local function type_draft(buf, s)
    local row = api.nvim_buf_get_mark(buf, ':')[1] - 1
    local lines = vim.split(s, '\n', { plain = true })
    local prefix = vim.fn.prompt_getprompt(buf)
    lines[1] = prefix .. lines[1]
    api.nvim_buf_set_lines(buf, row, -1, false, lines)
    api.nvim_buf_set_mark(buf, ':', row + 1, #prefix, {})
    assert(draft(buf) == s)
end

local function enter(buf)
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('A<CR><Esc>')
end

local function send(buf, s)
    ready(buf)
    type_draft(buf, s or 'hello')
    enter(buf)
end

local function turn(buf, n)
    await(function()
        return count(buf, '[completed]') >= (n or 1) and status(buf, 'ready')
    end, 'turn completed; transcript:\n' .. text(buf))
end

-- Close the chat and require the fake to have played the whole scenario.
local function finish(code)
    local rpc = last
    boomer.close()
    await(function()
        return rpc.exit ~= nil
    end, 'agent exit')
    assert(rpc.exit.code == (code or 0), 'scenario failed: ' .. rpc.stderr)
    vim.ui.select = function()
        error('unexpected selector')
    end
    vim.cmd('silent! only')
end

local function marks(buf, row, field, group)
    for _, m in
        ipairs(api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, {
            details = true,
            overlap = true,
        }))
    do
        if m[4][field] == group then
            return true
        end
    end
    return false
end

local function row_of(buf, needle)
    for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find(needle, 1, true) then
            return i - 1
        end
    end
    error('missing transcript text: ' .. needle)
end

-- Row of the virtual blank line above the live prompt, if any.
local function blank(buf)
    local ns = api.nvim_get_namespaces()['boomer.prompt']
    for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        if m[4].virt_lines then
            return m[2]
        end
    end
end

-- Text of the live prompt's non-blank virtual lines (the queue).
local function virtual(buf)
    local ns = api.nvim_get_namespaces()['boomer.prompt']
    local out = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        for _, line in ipairs(m[4].virt_lines or {}) do
            if #line > 0 then
                out[#out + 1] = line[1][1]
            end
        end
    end
    return table.concat(out, '\n')
end

local function pick(label)
    return function(items, opts, cb)
        for i, item in ipairs(items) do
            if opts.format_item(item):find(label, 1, true) then
                return cb(item, i)
            end
        end
        error('no choice ' .. label)
    end
end

local tests = {}
local function test(name, fn)
    tests[#tests + 1] = { name = name, fn = fn }
end

test('commands', function()
    assert(vim.fn.exists(':Boomer') == 2)
    assert(vim.fn.exists(':BoomerSettings') == 0 and vim.fn.exists(':BoomerSend') == 0)
    assert(not pcall(boomer.setup, { bogus = true }))
    assert(not pcall(boomer.setup, { backend = 'codex' }))
    assert(not pcall(boomer.setup, { agent = 'other' }))
    assert(not pcall(boomer.setup, { agents = { x = { command = 'x' } } }), 'protocol required')
    assert(not pcall(boomer.setup, { agents = { x = { protocol = 'x', command = 'x' } } }))
    assert(not pcall(boomer.setup, { agents = { codex = { args = 'x' } } }))
    assert(not pcall(boomer.setup, { agents = { codex = { bogus = 1 } } }))
    assert(not pcall(boomer.setup, { commands = { x = { desc = 'no action' } } }))
    assert(not pcall(boomer.setup, { commands = { x = { prompt = 'a', run = print } } }))
    assert(not pcall(boomer.setup, { commands = { ['a b'] = { prompt = 'a' } } }))
    assert(not pcall(boomer.setup, { winbar = 'x' }))
    assert(not pcall(boomer.setup, { winbar = { items = { 'agent' } } }), 'table winbar')
    assert(not pcall(boomer.setup, { start_insert = true }), 'removed option')
    assert(not pcall(boomer.setup, { cwd = '/tmp' }), 'removed option')
    assert(not pcall(boomer.setup, { window = { position = 'center' } }))
    assert(not pcall(boomer.setup, { window = { width = 0 } }))
    assert(not pcall(boomer.setup, { window = { size = 10 } }))
    assert(not pcall(boomer.setup, { labels = { agent = ' ' } }))
    assert(not pcall(boomer.setup, { labels = { user = 'x' } }))
    assert(not pcall(boomer.setup, { agents = { codex = { label = '' } } }))

    local config = require('boomer.config')
    boomer.setup({
        agent = 'myagent',
        agents = {
            myagent = { protocol = 'acp', command = 'my-agent', model = 'sonnet' },
            copilot = { args = { '--acp' } },
        },
        commands = { help = false, review = { prompt = 'Review $ARGUMENTS' } },
    })
    local p = assert(config.resolve())
    assert(p.name == 'myagent' and p.protocol == 'acp' and p.model == 'sonnet' and p.cwd == cwd)
    assert(vim.deep_equal(p.args, {}) and vim.deep_equal(p.options, {}))
    p = assert(config.resolve('copilot'))
    assert(p.command == 'copilot' and vim.deep_equal(p.args, { '--acp' }), 'args replace')
    local names = config.agent_names()
    assert(vim.tbl_contains(names, 'myagent') and vim.tbl_contains(names, 'gemini'))
    assert(vim.deep_equal(names, vim.fn.sort(vim.deepcopy(names))), 'names sorted')
    assert(not config.resolve('nope'))
    p.args[1] = 'changed'
    assert(config.resolve('copilot').args[1] == '--acp', 'resolve copies')

    -- The agent picker offers installed profiles, the default and the current one.
    boomer.setup({
        agent = 'goose',
        agents = vim.tbl_extend('force', absent, {
            codex = { command = fake },
            copilot = { command = '/missing-boomer-copilot' },
        }),
    })
    assert(
        vim.deep_equal(config.installed_agent_names('kimi'), { 'codex', 'goose', 'kimi' }),
        vim.inspect(config.installed_agent_names('kimi'))
    )

    -- Partial tables keep the other defaults; a float config replaces the default.
    boomer.setup({
        window = { position = 'float', float = { border = { '+', '-' } } },
        labels = { agent = 'Bot:' },
        winbar = false,
        agents = { copilot = { label = 'Copilot:' } },
    })
    local o = config.options
    assert(o.window.width == 0.5 and o.window.height == 0.5)
    assert(vim.deep_equal(o.window.float, { border = { '+', '-' } }), vim.inspect(o.window))
    assert(o.labels.prompt == 'Prompt:' and o.labels.agent == 'Bot:')
    assert(o.winbar == false)
    assert(
        config.resolve('codex').label == 'Bot:' and config.resolve('copilot').label == 'Copilot:'
    )
    boomer.setup()
    assert(config.options.window.position == 'right' and config.resolve().label == 'Agent:')
end)

test('slash command parsing', function()
    local commands = require('boomer.commands')
    assert(commands.parse('hello /model') == nil)
    assert(vim.deep_equal(commands.parse('/model  gpt-5 '), { name = 'model', args = 'gpt-5' }))
    assert(vim.deep_equal(commands.parse('/usage'), { name = 'usage', args = '' }))
    assert(vim.deep_equal(commands.parse('//model x'), { text = '/model x' }))
    assert(commands.parse('/ x') == nil and commands.parse('/a/b') == nil)
    assert(commands.parse('/review\nmore').name == 'review')
    local spec = { prompt = 'Check $ARGUMENTS now' }
    assert(commands.expand(spec, 'a.lua', {}) == 'Check a.lua now')
    assert(commands.expand({ prompt = 'Base' }, 'extra', {}) == 'Base\n\nextra')
    assert(commands.expand({ prompt = 'Base' }, '', {}) == 'Base')
    assert(commands.expand({
        prompt = function(args)
            return args:upper()
        end,
    }, 'x', {}) == 'X')
    local list = commands.list({ help = false, zed = { prompt = 'z', desc = 'Zed' } }, {
        plan = { name = 'plan', desc = 'Plan it' },
        zed = { name = 'zed' },
    }, true)
    local names = vim.tbl_map(function(i)
        return i.source .. ':' .. i.name
    end, list)
    assert(not vim.tbl_contains(names, 'builtin:help'), 'disabled builtin')
    assert(not vim.tbl_contains(names, 'builtin:close'), 'ex-only hidden in prompt')
    assert(vim.tbl_contains(names, 'user:zed') and not vim.tbl_contains(names, 'agent:zed'))
    assert(names[#names] == 'agent:plan', vim.inspect(names))
    assert(names[1] == 'builtin:agent', vim.inspect(names))
    local help = table.concat(commands.help(list), '\n')
    assert(help:find('/model [model] - Choose the model', 1, true), help)
    assert(help:find('/plan - Plan it', 1, true), help)
end)

test('status rendering', function()
    local st = require('boomer.status')
    local s = {
        agent = 'codex',
        model = 'gpt-5',
        effort = 'high',
        state = 'running',
        context = { used = 42000, size = 100000 },
        cost = { amount = 0.5, currency = 'USD' },
    }
    assert(st.text(s) == 'codex | gpt-5 (high) | running | ctx 42% | 0.50 USD', st.text(s))
    assert(st.statusline(s):find('ctx 42%%', 1, true), st.statusline(s))
    local bar = st.winbar(s)
    local rendered = api.nvim_eval_statusline(bar, { use_winbar = true, maxwidth = 100 }).str
    assert(rendered == string.rep(' ', 100 - #st.text(s)) .. st.text(s), rendered)
    assert(bar:find('%#BoomerWinbarBusy#running', 1, true), bar)
    assert(
        st.text({ agent = 'x', state = 'failed', context = { used = 1500 } })
            == 'x | failed | ctx 1.5k'
    )
    -- Rate limits; a nearly used-up window is highlighted.
    local limited = {
        agent = 'codex',
        limits = { primary = { used = 92.4, window = 300 }, secondary = { used = 10 } },
    }
    assert(st.text(limited) == 'codex | 5h 92% | wk 10%', st.text(limited))
    assert(st.winbar(limited):find('%#BoomerWinbarError#5h 92%%', 1, true), st.winbar(limited))
    assert(require('boomer.util').tokens(1234567) == '1.2M')

    -- An effort without a model, a mode, and a '%' in a value (escaped).
    assert(
        st.text({ agent = 'x', effort = 'low', mode = 'plan', state = 'ready' })
            == 'x | low | plan | ready'
    )
    assert(st.winbar({ agent = '100%', state = 'ready' }):find('100%%', 1, true))

    -- /usage lines.
    local usage = table.concat(st.usage(s), '\n')
    assert(usage:find('Context: 42.0k of 100.0k tokens (42%)', 1, true), usage)
    assert(usage:find('Cost: 0.50 USD', 1, true), usage)
    s.tokens, s.protocol = { total = 12345, input = 12000, output = 345 }, 'acp'
    usage = table.concat(st.usage(s), '\n')
    assert(usage:find('Last turn: 12.3k (12.0k in, 345 out)', 1, true), usage)
    assert(st.usage({ agent = 'x' })[2] == 'No usage reported yet')
end)

test('health', function()
    boomer.setup({
        agents = {
            codex = { command = '/missing-boomer-a' },
            copilot = { command = '/missing-boomer-b' },
        },
    })
    vim.cmd('checkhealth boomer')
    local out = text(api.nvim_get_current_buf())
    assert(
        out:find('codex (codex: /missing-boomer-a) [default]: executable not found', 1, true),
        out
    )
    vim.cmd('bwipeout!')
    boomer.setup()
end)

test('view rendering', function()
    local View = require('boomer.view')
    local view = View.new()
    local buf = view.buf
    vim.wo.conceallevel = 2
    view:open()
    assert(blank(buf) == nil, 'blank line above an empty transcript')
    assert(vim.wo.conceallevel == 0, 'chat concealed Markdown markers')
    assert(vim.treesitter.highlighter.active[buf], 'no treesitter highlighting')
    view:message('agent', '# He', 'a1')
    view:message('agent', 'llo\n**bold**', 'a1')
    view:message('agent', 'next', 'a2')
    view:write('[Tool: x]')
    view:message('user', 'restored', 'u1')
    view:message('user', '\nline', 'u1')
    view:write('Error: e', 'BoomerError')
    assert(
        text(buf)
            == 'Agent:\n# Hello\n**bold**\n\nAgent:\nnext\n\n[Tool: x]\n\n'
                .. 'Prompt: restored\nline\n\nError: e\n\nPrompt: ',
        text(buf)
    )
    local heading = row_of(buf, '# Hello')
    assert(marks(buf, heading - 1, 'hl_group', 'BoomerAssistantLabel'))
    local restored = row_of(buf, 'Prompt: restored')
    assert(marks(buf, restored, 'hl_group', 'BoomerUserLabel'))
    assert(not marks(buf, restored + 1, 'hl_group', 'BoomerUserLabel'))
    assert(marks(buf, row_of(buf, 'Error: e'), 'hl_group', 'BoomerError'))
    assert(marks(buf, row_of(buf, '[Tool: x]'), 'hl_group', 'BoomerSystem'))
    -- The output ends with a blank line: no virtual one is added.
    local prompt_row = view:row()
    assert(blank(buf) == nil, 'second blank line above the prompt')
    assert(marks(buf, prompt_row, 'hl_group', 'BoomerUserLabel'))

    -- Output while typing keeps the draft and the cursor column.
    keys('Adraft<S-CR>second<Esc>')
    local ok, err
    vim.keymap.set('i', '<F5>', function()
        ok, err = xpcall(function()
            local col = api.nvim_win_get_cursor(0)[2]
            view:message('agent', 'hel')
            view:message('agent', 'lo')
            assert(view:draft() == 'draft\nsecond', 'output corrupted input')
            assert(vim.fn.mode() == 'i' and api.nvim_win_get_cursor(0)[2] == col)
        end, debug.traceback)
    end, { buffer = buf })
    keys('A<F5><Esc>')
    assert(ok, err)
    assert(has(buf, 'Error: e\n\nAgent:\nhello\nPrompt: draft\nsecond'), text(buf))
    -- Streamed output ends without a blank line: a virtual one separates the prompt.
    local draft_row = row_of(buf, 'Prompt: draft')
    assert(blank(buf) == draft_row, 'no blank line above the prompt')

    -- Submitted input stays as typed: it is already a user message.
    local first = row_of(buf, 'Prompt: draft')
    vim.fn.prompt_setcallback(buf, function(s)
        view:submitted(s)
    end)
    keys('A<CR><Esc>')
    assert(has(buf, 'Agent:\nhello\nPrompt: draft\nsecond\nPrompt: '), text(buf))
    assert(marks(buf, first, 'hl_group', 'BoomerUserLabel'))
    local row, col = view:row()
    assert(row == first + 2 and col == #'Prompt: ', 'input mark moved')
    assert(blank(buf) == row, 'blank line did not follow the prompt')
    assert(marks(buf, row, 'hl_group', 'BoomerUserLabel'), 'label not on the new prompt')

    api.nvim_set_hl(0, 'BoomerUserLabel', { fg = '#234567' })
    vim.cmd.colorscheme('default')
    assert(
        api.nvim_get_hl(0, { name = 'BoomerUserLabel' }).link == 'Title',
        'defaults not restored'
    )
    api.nvim_buf_delete(buf, { force = true })

    -- Custom labels; trailing space on the user label is not doubled.
    view = View.new({ labels = { user = 'Me> ', agent = 'Bot:' } })
    view:message('agent', 'hi')
    view:message('user', 'yo')
    assert(text(view.buf) == 'Bot:\nhi\n\nMe> yo\nMe> ', text(view.buf))
    assert(vim.fn.prompt_getprompt(view.buf) == 'Me> ')
    api.nvim_buf_delete(view.buf, { force = true })
end)

test('window layout', function()
    local View = require('boomer.view')
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
    local rows = vim.o.lines - vim.o.cmdheight
    local function show(window)
        vim.cmd('silent! only')
        local view = View.new({ window = window })
        view:open()
        local win = api.nvim_get_current_win()
        assert(api.nvim_win_get_buf(win) == view.buf)
        return view, win
    end
    local function done(view)
        api.nvim_buf_delete(view.buf, { force = true })
    end

    -- Default: right split of half the editor, editor-wide even beside other splits.
    vim.cmd('silent! only')
    vim.cmd('split')
    local view = View.new()
    view:open()
    local win = api.nvim_get_current_win()
    local layout = vim.fn.winlayout()
    assert(layout[1] == 'row' and layout[2][2][2] == win, vim.inspect(layout))
    assert(api.nvim_win_get_width(win) == 60, api.nvim_win_get_width(win))
    assert(vim.wo[win].wrap and not vim.wo[win].number)
    done(view)

    view, win = show({ position = 'left', width = 30 })
    layout = vim.fn.winlayout()
    assert(layout[1] == 'row' and layout[2][1][2] == win, vim.inspect(layout))
    assert(api.nvim_win_get_width(win) == 30)
    done(view)

    view, win = show({ position = 'top', height = 0.25 })
    layout = vim.fn.winlayout()
    assert(layout[1] == 'col' and layout[2][1][2] == win, vim.inspect(layout))
    assert(api.nvim_win_get_height(win) == math.floor(rows * 0.25 + 0.5))
    done(view)

    view, win = show({ position = 'bottom', height = 10 })
    layout = vim.fn.winlayout()
    assert(layout[1] == 'col' and layout[2][2][2] == win, vim.inspect(layout))
    assert(api.nvim_win_get_height(win) == 10)
    done(view)

    -- Floats are centered, take extra config and follow the editor size.
    view, win = show({
        position = 'float',
        width = 0.5,
        height = 20,
        float = { border = 'single', title = 'Boomer' },
    })
    local cfg = api.nvim_win_get_config(win)
    assert(cfg.relative == 'editor' and cfg.width == 60 and cfg.height == 20, vim.inspect(cfg))
    assert(cfg.col == 29 and cfg.row == math.floor((rows - 22) / 2), vim.inspect(cfg))
    assert(cfg.title and cfg.title[1][1] == 'Boomer', vim.inspect(cfg.title))
    vim.o.columns = 200
    api.nvim_exec_autocmds('VimResized', {})
    cfg = api.nvim_win_get_config(win)
    assert(cfg.width == 100 and cfg.col == 49, vim.inspect(cfg))
    view:open()
    assert(#api.nvim_list_wins() == 2, 'open() did not reuse the float')
    done(view)
    vim.o.columns, vim.o.lines = columns, lines
    vim.cmd('silent! only')
end)

test('codex chat', function()
    -- A delayed multiline turn, then a second turn in the same session.
    local scenario = load('codex-basic')
    local again = steps(scenario, 6)
    scenario.steps[6].message.params.input[1].text = 'hello\nworld'
    table.insert(scenario.steps, 9, { op = 'delay', ms = 150 })
    table.insert(scenario.steps, 2, { op = 'delay', ms = 60 })
    vim.list_extend(scenario.steps, again)
    local windows = #api.nvim_list_wins()
    local buf = open(scenario)
    assert(#api.nvim_list_wins() == windows + 1, 'chat must open a split')
    assert(vim.bo[buf].buftype == 'prompt' and vim.bo[buf].bufhidden == 'hide')
    assert(not vim.bo[buf].swapfile and vim.bo[buf].filetype == 'boomer')
    assert(status(buf, 'starting'))

    keys('Ahello<S-CR>world<CR><Esc>')
    assert(draft(buf) == '' and state(buf).queued == 1, 'Enter during startup did not queue')
    assert(virtual(buf) == 'Queued: hello (+1 line)', virtual(buf))
    -- The queued prompt is sent once the session is ready.
    await(function()
        return status(buf, 'running')
    end, 'queued prompt sent')
    assert(state(buf).queued == nil and virtual(buf) == '', virtual(buf))
    type_draft(buf, ' \n ')
    enter(buf)
    assert(draft(buf) == ' \n ', 'empty prompt was sent')
    local row = row_of(buf, 'Prompt: hello')
    assert(progress[#progress].status == 'running')
    assert(marks(buf, row, 'hl_group', 'BoomerUserLabel'))
    await(function()
        return has(buf, 'Agent:\nhello')
    end, 'streamed text')

    type_draft(buf, 'keep\nthis')
    assert(not boomer.resume() and not boomer.new())
    vim.cmd('wincmd p')
    local code = api.nvim_get_current_win()
    turn(buf)
    assert(api.nvim_get_current_win() == code, 'streaming stole focus')
    assert(draft(buf) == 'keep\nthis', 'streaming overwrote the draft')
    assert(progress[#progress].status == 'success')
    assert(
        has(buf, 'Prompt: hello\nworld\n\nAgent:\nhello\n\n[completed]\n\nPrompt: keep'),
        text(buf)
    )

    -- History is read-only; reopening reuses the chat; hiding keeps it.
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    local before = text(buf)
    keys('ggdd')
    assert(text(buf) == before, 'history was editable')
    assert(boomer.open() == buf)
    send(buf, 'hello')
    turn(buf, 2)
    assert(count(buf, 'Agent:\nhello') == 2)
    vim.cmd('close')
    assert(boomer.open() == buf, 'hidden chat was not reused')
    vim.cmd('only')
    assert(boomer.open() == buf)
    finish()
    assert(not api.nvim_buf_is_valid(buf), 'close did not wipe the buffer')
end)

test('insert mode and labels', function()
    play(load('codex-basic'), nil, {
        labels = { prompt = 'Me>' },
        agents = { codex = { label = 'Codex:' } },
    })
    local mode, cursor
    _G.boomer_probe = function()
        mode, cursor = api.nvim_get_mode().mode, api.nvim_win_get_cursor(0)
    end
    keys('<Cmd>Boomer<CR><Cmd>lua boomer_probe()<CR><Esc>')
    local buf = api.nvim_get_current_buf()
    assert(vim.bo[buf].filetype == 'boomer')
    assert(mode == 'i', 'opened in mode ' .. tostring(mode))
    assert(cursor[1] == api.nvim_buf_line_count(buf) and cursor[2] == #'Me> ', vim.inspect(cursor))
    send(buf)
    turn(buf)
    assert(has(buf, 'Me> hello\n\nCodex:\nhello'), text(buf))
    assert(marks(buf, row_of(buf, 'Codex:'), 'hl_group', 'BoomerAssistantLabel'))

    -- Focusing the chat from another window, with the cursor in the history.
    api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('wincmd p')
    keys('<Cmd>Boomer<CR><Cmd>lua boomer_probe()<CR><Esc>')
    assert(api.nvim_get_current_buf() == buf and mode == 'i')
    assert(cursor[1] == api.nvim_buf_line_count(buf), vim.inspect(cursor))
    _G.boomer_probe = nil
    finish()
end)

test('pickers return to insert mode', function()
    local buf = open(load('acp-config'), 'copilot')
    ready(buf)
    local log = {}
    local startinsert = vim.cmd.startinsert
    rawset(vim.cmd, 'startinsert', function(...)
        log[#log + 1] = api.nvim_get_current_buf() == buf and 'insert' or 'elsewhere'
        return startinsert(...)
    end)
    -- Like most pickers, leave Insert mode and answer later.
    local answers = { 'Model', 'Two', 'Model' }
    vim.ui.select = function(items, opts, cb)
        log[#log + 1] = 'pick ' .. api.nvim_get_mode().mode
        vim.cmd.stopinsert()
        vim.defer_fn(function()
            if answers[1] then
                pick(table.remove(answers, 1))(items, opts, cb)
            else
                cb(nil)
            end
        end, 10)
    end
    -- /settings typed in Insert mode: back to Insert once the chained pickers end.
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('A/settings<CR>', '!')
    await(function()
        return has(buf, '[Setting: model = Two]') and #log == 3
    end, 'setting; log: ' .. vim.inspect(log))
    assert(vim.deep_equal(log, { 'pick i', 'pick n', 'insert' }), vim.inspect(log))
    -- Dismissed after the first picker.
    log = {}
    keys('A/settings<CR>', '!')
    await(function()
        return #log == 3
    end, 'dismissal; log: ' .. vim.inspect(log))
    assert(vim.deep_equal(log, { 'pick i', 'pick n', 'insert' }), vim.inspect(log))
    -- Opened from Normal mode: stays there.
    log = {}
    vim.cmd.stopinsert()
    assert(boomer.settings())
    pause(50)
    assert(vim.deep_equal(log, { 'pick n' }), vim.inspect(log))
    rawset(vim.cmd, 'startinsert', nil)
    finish()
end)

test('pickers answering in terminal mode', function()
    -- Mode changes need the main loop: drive a child Neovim. Its picker answers
    -- in Terminal mode, which ends after the answer (like fzf-lua).
    stage(load('acp-config'))
    local child = vim.fn.jobstart({ vim.v.progpath, '--embed', '--headless', '--clean' }, {
        rpc = true,
    })
    local function lua(code, ...)
        return vim.rpcrequest(child, 'nvim_exec_lua', code, { ... })
    end
    local function mode()
        return vim.rpcrequest(child, 'nvim_get_mode').mode
    end
    vim.rpcrequest(child, 'nvim_ui_attach', 80, 24, {})
    lua(
        [[
        local root, fake = ...
        vim.opt.rtp:prepend(root)
        vim.cmd.runtime('plugin/boomer.lua')
        require('boomer').setup({
            agent = 'copilot',
            agents = { copilot = { command = fake } },
        })
        vim.ui.select = function(items, _, cb)
            local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
                relative = 'editor', row = 1, col = 1, width = 20, height = 3,
            })
            -- Any program that waits until it is stopped.
            local job = vim.fn.jobstart({ vim.v.progpath, '--clean', '--headless' }, {
                term = true,
                on_exit = function()
                    vim.api.nvim_win_close(win, true)
                    cb(items[#items])
                end,
            })
            vim.keymap.set('t', '<CR>', function()
                vim.fn.jobstop(job)
            end, { buffer = true })
            vim.cmd.startinsert()
        end
        _G.buf = require('boomer').open()
    ]],
        root,
        fake
    )
    local function ready()
        return lua("return (require('boomer').status() or {}).state") == 'ready'
    end
    await(ready, 'child ready')
    assert(mode() == 'i', mode())
    vim.rpcrequest(child, 'nvim_input', '/model<CR>')
    await(function()
        return mode() == 't'
    end, 'child picker')
    vim.rpcrequest(child, 'nvim_input', '<CR>')
    await(function()
        local lines = lua('return vim.api.nvim_buf_get_lines(_G.buf, 0, -1, false)')
        return vim.list_contains(lines, '[Setting: model = Two]') and ready()
    end, 'child setting')
    pause(50)
    local m, ft = mode(), lua('return vim.bo.filetype')
    vim.fn.jobstop(child)
    assert(m == 'i' and ft == 'boomer', m .. ' ' .. ft)
end)

test('acp chat', function()
    -- Unknown requests get -32601; a final response survives an immediate exit.
    local buf = open(load('acp-unknown'), 'copilot')
    send(buf)
    turn(buf)
    assert(count(buf, 'Agent:\nhello') == 1)
    boomer.permissions('auto')
    assert(notices[#notices] == 'This agent offers no permissions setting', notices[#notices])
    finish()

    buf = open(load('acp-final-exit'), 'copilot')
    send(buf)
    await(function()
        return status(buf, 'closed')
    end, 'exit after final response')
    assert(has(buf, 'hello\n\n[completed]'), text(buf))
    assert(has(buf, 'Error: agent exited with code 0'), text(buf))
    assert(not boomer.settings(), 'dead chat accepted a command')
    finish()
end)

test('settings', function()
    local scenario = load('codex-basic')
    local models = load('codex-models')
    table.insert(scenario.steps, 6, models.steps[4])
    table.insert(scenario.steps, 7, models.steps[5])
    scenario.steps[8].message.params.model = 'm2'
    scenario.steps[8].message.params.effort = 'high'
    local buf = open(scenario)
    ready(buf)
    local n = 0
    vim.ui.select = function(items, opts, cb)
        n = n + 1
        local label = opts.format_item(items[1])
        if n == 1 then
            assert(label == 'Model | m1', label)
        end
        cb(items[(n == 2 or n == 3) and 2 or 1])
    end
    assert(boomer.settings())
    await(function()
        return has(buf, '[Setting: model =')
    end, 'model')
    assert(boomer.settings())
    await(function()
        return has(buf, '[Setting: effort = high]')
    end, 'effort')
    send(buf)
    turn(buf)
    finish()

    -- ACP: grouped choices and booleans keep native values.
    scenario = load('acp-config')
    local options = scenario.steps[4].message.result.configOptions
    options[1].options = { { name = 'Family', options = options[1].options } }
    options[2] = { id = 'enabled', name = 'Enabled', type = 'boolean', currentValue = true }
    local request, response = vim.deepcopy(scenario.steps[5]), vim.deepcopy(scenario.steps[6])
    request.message.params.configId, request.message.params.value = 'enabled', false
    response.message.result.configOptions = vim.deepcopy(options)
    response.message.result.configOptions[2].currentValue = false
    table.insert(scenario.steps, 5, request)
    table.insert(scenario.steps, 6, response)
    buf = open(scenario, 'copilot')
    ready(buf)
    -- A setting without a command of its own is named by /settings.
    send(buf, '/settings nope false')
    assert(notices[#notices] == 'Unknown setting: nope', notices[#notices])
    send(buf, '/settings enabled false')
    await(function()
        return has(buf, 'Prompt: /settings enabled false\n\n[Setting: enabled = false]')
    end, 'boolean')
    local choices = { 'Model', 'Family / Two' }
    n = 0
    vim.ui.select = function(items, opts, cb)
        n = n + 1
        pick(choices[n])(items, opts, cb)
    end
    assert(boomer.settings())
    await(function()
        return has(buf, '[Setting: model = Family / Two]')
    end, 'grouped')
    finish()

    -- Dismissal, selector errors and backend errors.
    scenario = load('acp-config')
    scenario.steps[6].message.result = nil
    scenario.steps[6].message.error = { code = -32000, message = 'configuration refused' }
    buf = open(scenario, 'copilot')
    ready(buf)
    vim.ui.select = function(_, _, cb)
        cb(nil)
    end
    assert(boomer.settings())
    pause(20)
    vim.ui.select = function()
        error('selector failed')
    end
    assert(boomer.settings())
    await(function()
        return has(buf, 'selector failed')
    end, 'selector error')
    vim.ui.select = function(items, _, cb)
        cb(items[#items])
    end
    assert(boomer.settings())
    await(function()
        return has(buf, 'Error: configuration refused')
    end, 'backend error')
    -- A picker that closes without calling back (fzf-lua on <Esc>) blocks
    -- nothing; its late answer is ignored once a newer picker opened.
    local late
    vim.ui.select = function(items, _, cb)
        late = function()
            cb(items[1])
        end
    end
    assert(boomer.settings())
    pause(20)
    local stale = late
    assert(boomer.settings(), 'a silently closed picker blocks settings')
    pause(20)
    stale()
    pause(20)
    assert(not has(buf, '[Setting:'), 'stale picker answer applied')
    finish()
    late()
    pause(20)
end)

test('permissions', function()
    local function run(name, select, backend)
        vim.ui.select = select
        local buf = open(load(name), backend)
        send(buf)
        turn(buf)
        assert(count(buf, 'Agent:\nhello') == 1)
        assert(not has(buf, 'Allow for this session'), 'choices dumped into transcript')
        assert(not text(buf):find('Error: Permission %d'), text(buf))
        finish()
        return buf
    end
    run('codex-permission-accept', function(items, opts, cb)
        assert(opts.format_item(items[1]) == 'Deny', 'Deny must come first')
        local permission = 'Permission: Run command\ncommand: true\ncwd: ' .. cwd
        assert(has(api.nvim_get_current_buf(), permission))
        for _, item in ipairs(items) do
            assert(item.label ~= 'Decline', 'Deny and Decline duplicated')
        end
        pick('Allow once')(items, opts, cb)
    end)
    run('codex-permission-deny', pick('Deny'))
    run('codex-permission-deny', function(_, _, cb)
        cb(nil)
    end)
    run('codex-permission-deny', function()
        error('selector failed')
    end)
    run('codex-fileChange', pick('Allow once'))
    run('codex-permissions', pick('Grant for this turn'))
    run('acp-permission-accept', pick('Allow once'), 'copilot')
    run('acp-permission-deny', pick('Deny'), 'copilot')

    -- A structured policy amendment is passed through unchanged.
    local scenario = load('codex-permission-accept')
    local decision = { acceptWithExecpolicyAmendment = { execpolicy_amendment = { 'echo' } } }
    scenario.steps[8].message.params.availableDecisions = { 'decline', decision }
    scenario.steps[9].message.result.decision = decision
    vim.ui.select = pick('Policy change:')
    local buf = open(scenario)
    send(buf)
    turn(buf)
    finish()
end)

test('permission queue and cancel', function()
    -- Two simultaneous requests open one selector at a time.
    local scenario = load('codex-permission-accept')
    local request, response = vim.deepcopy(scenario.steps[8]), vim.deepcopy(scenario.steps[9])
    request.message.id, response.message.id = 'permission2', 'permission2'
    table.insert(scenario.steps, 9, request)
    table.insert(scenario.steps, 11, response)
    local open_selectors = {}
    vim.ui.select = function(items, _, cb)
        open_selectors[#open_selectors + 1] = function()
            cb(items[2])
        end
    end
    local buf = open(scenario)
    send(buf)
    await(function()
        return #open_selectors == 1
    end, 'first selector')
    pause(50)
    assert(#open_selectors == 1, 'selectors overlapped')
    open_selectors[1]()
    await(function()
        return #open_selectors == 2
    end, 'second selector')
    open_selectors[2]()
    turn(buf)
    finish()

    -- A permission picker closed without an answer is shown again by :Boomer.
    local shown = 0
    vim.ui.select = function()
        shown = shown + 1
    end
    buf = open(load('codex-permission-accept'))
    send(buf)
    await(function()
        return shown == 1
    end, 'permission picker')
    vim.ui.select = pick('Allow once')
    vim.cmd('Boomer')
    turn(buf)
    assert(has(buf, 'Permission: Allow once'), text(buf))
    finish()

    -- Cancel settles the pending approval; a late answer is ignored.
    for _, case in ipairs({ { 'codex-permission-cancel' }, { 'acp-permission-cancel', 'copilot' } }) do
        local answer
        vim.ui.select = function(items, _, cb)
            answer = function()
                cb(items[2])
            end
        end
        buf = open(load(case[1]), case[2])
        send(buf)
        await(function()
            return answer ~= nil
        end, 'pending permission')
        keys('<C-c>')
        assert(status(buf, 'cancelling'), 'normal-mode <C-c> did not cancel')
        await(function()
            return has(buf, '[cancelled]') and status(buf, 'ready')
        end, 'cancelled turn')
        answer()
        pause(30)
        assert(not has(buf, 'Permission: Allow'), 'late answer was applied')
        finish()
    end
end)

test('tool lines', function()
    local scenario = load('codex-basic')
    local function item(method, it)
        return { method = method, params = { threadId = 's1', item = it } }
    end
    table.insert(scenario.steps, 8, {
        op = 'send_notification',
        messages = {
            item('item/started', { type = 'agentMessage' }),
            item('item/started', { type = 'plan' }),
            item('item/started', { type = 'commandExecution', command = 'true' }),
            item('item/completed', { type = 'commandExecution', command = 'true' }),
            item('item/started', { type = 'commandExecution', command = 'false' }),
            item(
                'item/completed',
                { type = 'commandExecution', command = 'false', status = 'failed' }
            ),
            { method = 'item/reasoning/textDelta', params = { threadId = 's1', delta = 'hidden' } },
        },
    })
    local buf = open(scenario)
    send(buf)
    turn(buf)
    assert(count(buf, '[Tool:') == 3, text(buf))
    assert(has(buf, '[Tool: true]') and has(buf, '[Tool: false | failed]'))
    assert(not has(buf, 'hidden'), 'reasoning was displayed')
    finish()

    scenario = load('acp-basic')
    local function update(u)
        return { method = 'session/update', params = { sessionId = 's1', update = u } }
    end
    table.insert(scenario.steps, 6, {
        op = 'send_notification',
        messages = {
            update({ sessionUpdate = 'tool_call', toolCallId = 't1', title = 'read' }),
            update({
                sessionUpdate = 'tool_call_update',
                toolCallId = 't1',
                status = 'in_progress',
            }),
            update({ sessionUpdate = 'tool_call_update', toolCallId = 't1', status = 'failed' }),
            update({
                sessionUpdate = 'user_message_chunk',
                content = { type = 'text', text = 'echo' },
            }),
        },
    })
    buf = open(scenario, 'copilot')
    send(buf)
    turn(buf)
    assert(count(buf, '[Tool:') == 2 and has(buf, '[Tool: read | failed]'), text(buf))
    assert(not has(buf, 'echo'), 'live user echo duplicated the prompt')
    finish()
end)

test('cancel', function()
    -- Cancel before Codex returns the turn ID is sent once the ID arrives.
    local buf = open(load('codex-early-cancel'))
    send(buf)
    assert(boomer.cancel() and status(buf, 'cancelling'))
    await(function()
        return has(buf, '[cancelled]') and status(buf, 'ready')
    end, 'early cancel')
    finish()

    -- A failed interrupt is reported and cancel can be retried; the chat lives on.
    local scenario = load('codex-early-cancel')
    scenario.steps[10].message.result = nil
    scenario.steps[10].message.error = { code = -1, message = 'no' }
    table.insert(scenario.steps, 11, vim.deepcopy(scenario.steps[9]))
    table.insert(
        scenario.steps,
        12,
        { op = 'send_response', message = { id = { ref = 'interrupt' }, result = {} } }
    )
    buf = open(scenario)
    send(buf)
    boomer.cancel()
    await(function()
        return has(buf, 'cancel failed: no') and status(buf, 'running')
    end, 'cancel failure')
    assert(boomer.cancel())
    await(function()
        return has(buf, '[cancelled]') and status(buf, 'ready')
    end, 'retried cancel')
    finish()

    -- An agent that never answers: closing mid-turn ends the progress message.
    buf = open(load('acp-hang'), 'copilot')
    send(buf)
    assert(boomer.cancel())
    pause(50)
    assert(status(buf, 'cancelling'))
    finish()
    assert(progress[#progress].status == 'failed')
end)

test('process failures', function()
    -- Exit reports the code and stderr; the draft survives.
    local scenario = load('codex-basic')
    for i = #scenario.steps, 6, -1 do
        scenario.steps[i] = nil
    end
    vim.list_extend(scenario.steps, {
        { op = 'delay', ms = 50 },
        { op = 'stderr', data = 'boom\n' },
        { op = 'exit', code = 3 },
    })
    local buf = open(scenario)
    ready(buf)
    type_draft(buf, 'keep')
    await(function()
        return status(buf, 'closed')
    end, 'disconnect')
    assert(has(buf, 'Error: agent exited with code 3:\nboom'), text(buf))
    assert(draft(buf) == 'keep')
    enter(buf)
    assert(draft(buf) == 'keep', 'dead chat accepted a prompt')
    finish(3)

    -- Startup failures leave an inspectable buffer.
    buf = open(load('acp-exit'), 'copilot')
    await(function()
        return status(buf, 'closed')
    end, 'startup exit')
    assert(count(buf, 'Error:') == 1, 'exit error repeated: ' .. text(buf))
    finish(7)
    buf = open(load('acp-auth'), 'copilot')
    await(function()
        return status(buf, 'failed')
    end, 'session error')
    assert(has(buf, 'Error: Authentication required'))
    boomer.close()
    buf = open(load('acp-version'), 'copilot')
    await(function()
        return status(buf, 'failed')
    end, 'version error')
    assert(has(buf, 'Error: unsupported ACP version'), text(buf))
    boomer.close()
    boomer.setup({
        agents = { codex = { command = '/missing-boomer-test-executable' } },
    })
    buf = boomer.open()
    assert(status(buf, 'failed') and has(buf, 'Error:'), text(buf))
    -- An agent that exited can be restarted or replaced.
    assert(boomer.agent('codex'))
    assert(not api.nvim_buf_is_valid(buf))
    buf = api.nvim_get_current_buf()
    assert(status(buf, 'failed') and state(buf).agent == 'codex', text(buf))
    boomer.close()

    -- Malformed lines are reported and skipped.
    scenario = load('acp-basic')
    table.insert(scenario.steps, 2, { op = 'write_raw', data = 'garbage\n' })
    buf = open(scenario, 'copilot')
    send(buf)
    turn(buf)
    assert(has(buf, 'ignored malformed message: garbage'))
    finish()

    -- :bd and :bw close the agent and leave no buffer behind.
    scenario = load('codex-basic')
    for i = #scenario.steps, 6, -1 do
        scenario.steps[i] = nil
    end
    for _, unload in ipairs({ false, true }) do
        buf = open(scenario)
        ready(buf)
        local rpc = last
        api.nvim_buf_delete(buf, { force = true, unload = unload })
        await(function()
            return rpc.exit and not api.nvim_buf_is_valid(buf)
        end, 'buffer teardown')
        assert(rpc.exit.code == 0, rpc.stderr)
        assert(boomer.open() ~= buf)
        boomer.close()
    end

    -- An agent ignoring EOF and SIGTERM is killed. Windows has no signals:
    -- the agent (behind fake.cmd, like an npm shim) is ended with its parent.
    buf = open(load('acp-forced-cleanup'), 'copilot')
    pause(100)
    local rpc = last
    boomer.close()
    await(function()
        return rpc.exit ~= nil
    end, 'forced cleanup')
    if windows then
        assert(rpc.exit.code ~= 0, vim.inspect(rpc.exit) .. rpc.stderr)
    else
        assert(rpc.exit.signal == 9, vim.inspect(rpc.exit) .. rpc.stderr)
    end
end)

test('sessions', function()
    -- No chat open: pick a saved Codex thread; paginated history is replayed.
    local list = load('codex-sessions')
    local resume = load('codex-resume-paginated')
    play({ version = 1, profile = 'codex-v2', steps = steps(list, 1, nil, resume, 4) }, 'codex')
    local labels
    vim.ui.select = function(items, opts, cb)
        labels = vim.tbl_map(opts.format_item, items)
        cb(items[2])
    end
    boomer.resume()
    local buf = api.nvim_get_current_buf()
    ready(buf)
    assert(labels[1] == 'Saved chat 2 | ' .. os.date('%Y-%m-%d %H:%M', 1794736802), labels[1])
    assert(state(buf).session == 's1')
    assert(has(buf, 'Prompt: old question\n\nAgent:\nold answer'), text(buf))
    assert(has(buf, 'Prompt: [image]') and not has(buf, '[Tool:'), text(buf))
    send(buf)
    turn(buf)
    finish()

    -- Dismissing the picker with no chat starts a new session.
    local basic = load('codex-basic')
    play({ version = 1, profile = 'codex-v2', steps = steps(list, 1, 5, basic, 4, 5) })
    vim.ui.select = function(_, _, cb)
        cb(nil)
    end
    boomer.resume()
    ready(api.nvim_get_current_buf())
    finish()

    -- A picker closed without an answer leaves a usable chat with no session.
    play({ version = 1, profile = 'codex-v2', steps = steps(list, 1, 5, basic, 4, 5) })
    vim.ui.select = function() end
    boomer.resume()
    await(function()
        return status(api.nvim_get_current_buf(), 'no session')
    end, 'no session')
    assert(boomer.new())
    ready(api.nvim_get_current_buf())
    finish()

    -- With a chat open: switch on the same process into a fresh buffer.
    local acp = load('acp-sessions')
    local new = load('acp-basic')
    local load_steps = steps(load('acp-resume-replay'), 3)
    local scenario = {
        version = 1,
        profile = 'acp-v1',
        steps = steps(acp, 1, 2, new, 3, 4, acp, 3, 4),
    }
    vim.list_extend(scenario.steps, load_steps)
    vim.list_extend(scenario.steps, steps(new, 3, 4))
    scenario.steps[4].message.result.sessionId = 's0'
    scenario.steps[#scenario.steps].message.result.sessionId = 's3'
    local old = open(scenario, 'copilot')
    ready(old)
    local rpc = last
    vim.cmd('vsplit')
    type_draft(old, 'draft')
    assert(not boomer.resume(), 'switch with a draft')
    type_draft(old, '')
    vim.ui.select = function(items, opts, cb)
        labels = vim.tbl_map(opts.format_item, items)
        cb(items[2])
    end
    assert(boomer.resume())
    await(function()
        return not api.nvim_buf_is_valid(old)
    end, 'old buffer wiped')
    buf = api.nvim_get_current_buf()
    assert(#vim.fn.win_findbuf(buf) == 2, 'windows did not follow the switch')
    assert(labels[1] == 'Saved chat 2 | 2026-11-15 12:00', labels[1])
    ready(buf)
    assert(has(buf, 'Prompt: old question\n\nAgent:\nold answer'), text(buf))
    send(buf)
    turn(buf)
    assert(boomer.new())
    local fresh = api.nvim_get_current_buf()
    assert(fresh ~= buf and not api.nvim_buf_is_valid(buf))
    ready(fresh)
    assert(state(fresh).session == 's3' and last == rpc, 'switch started a new process')
    finish()

    -- A failed load is reported in the new buffer and the chat stays usable.
    local refused = load('codex-resume-error')
    refused.steps[4].message.params.threadId = 's2'
    scenario = {
        version = 1,
        profile = 'codex-v2',
        steps = steps(basic, 1, 5, list, 4, 5, refused, 4, 5, basic, 4, 5),
    }
    old = open(scenario)
    ready(old)
    vim.ui.select = pick('Saved chat 2')
    boomer.resume()
    await(function()
        return status(api.nvim_get_current_buf(), 'failed')
    end, 'failed load')
    buf = api.nvim_get_current_buf()
    assert(buf ~= old and has(buf, 'Error: session load refused'), text(buf))
    type_draft(buf, 'x')
    enter(buf)
    assert(draft(buf) == 'x', 'sent without a session')
    type_draft(buf, '')
    assert(boomer.new())
    ready(api.nvim_get_current_buf())
    finish()

    -- List errors are notified; the chat is untouched.
    scenario = {
        version = 1,
        profile = 'codex-v2',
        steps = steps(basic, 1, 5, load('codex-sessions-error'), 4, 5),
    }
    buf = open(scenario)
    ready(buf)
    boomer.resume()
    await(function()
        return notices[#notices] == 'session list refused'
    end, 'list error')
    assert(api.nvim_buf_is_valid(buf) and status(buf, 'ready'))
    finish()
end)

local function expect(method, params, capture)
    return {
        op = 'expect_request',
        message = { id = { capture = capture or 'req' }, method = method, params = params },
    }
end

local function respond(result, ref)
    return { op = 'send_response', message = { id = { ref = ref or 'req' }, result = result } }
end

local function notify(method, params)
    return { op = 'send_notification', message = { method = method, params = params } }
end

-- Evaluate the chat window's winbar as Neovim draws it.
local function winbar(buf, padded)
    local win = vim.fn.win_findbuf(buf)[1]
    vim.g.statusline_winid = win
    -- Wide enough not to truncate in the narrow test window.
    local opts = { winid = win, use_winbar = true, maxwidth = 200 }
    local s = api.nvim_eval_statusline(vim.wo[win].winbar, opts).str
    vim.g.statusline_winid = nil
    return padded and s or (s:gsub('^ +', ''))
end

test('codex slash commands', function()
    local base, models = load('codex-basic'), load('codex-models')
    local function codex_turn(text, extra)
        local s = steps(base, 6, 9)
        s[1].message.params.input[1].text = text
        s[1].message.params.model, s[1].message.params.effort = 'm2', 'high'
        if extra then
            table.insert(s, 4, extra)
        end
        return s
    end
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 5) }
    vim.list_extend(scenario.steps, steps(models, 4, 5))
    local resets = os.time() + 3600
    vim.list_extend(
        scenario.steps,
        codex_turn('/hello', {
            op = 'send_notification',
            messages = {
                {
                    method = 'thread/tokenUsage/updated',
                    params = {
                        threadId = 's1',
                        turnId = 't1',
                        tokenUsage = {
                            total = { totalTokens = 1500, inputTokens = 1000, outputTokens = 500 },
                            last = { totalTokens = 42000 },
                            modelContextWindow = 100000,
                        },
                    },
                },
                {
                    method = 'account/rateLimits/updated',
                    params = {
                        rateLimits = {
                            limitId = 'codex',
                            primary = {
                                usedPercent = 30,
                                windowDurationMins = 300,
                                resetsAt = resets,
                            },
                        },
                    },
                },
                {
                    method = 'account/rateLimits/updated',
                    params = { rateLimits = { limitId = 'other', primary = { usedPercent = 99 } } },
                },
            },
        })
    )
    vim.list_extend(scenario.steps, {
        -- Sparse: the 5h window keeps its reset time from the update.
        expect('account/rateLimits/read', vim.empty_dict()),
        respond({
            rateLimits = {
                primary = { usedPercent = 40 },
                secondary = {
                    usedPercent = 12,
                    windowDurationMins = 10080,
                    resetsAt = resets + 2 * 86400,
                },
            },
        }),
        expect('thread/compact/start', { threadId = 's1' }),
        respond(vim.empty_dict()),
        notify(
            'turn/started',
            { threadId = 's1', turn = { id = 't2', items = {}, status = 'inProgress' } }
        ),
        notify(
            'turn/completed',
            { threadId = 's1', turn = { id = 't2', items = {}, status = 'completed' } }
        ),
    })
    vim.list_extend(scenario.steps, codex_turn('Review main.lua carefully'))
    local resumed = vim.deepcopy(base.steps[5])
    resumed.message.result.thread.id = 's9'
    resumed.message.id.ref = 'resume'
    vim.list_extend(scenario.steps, {
        expect('thread/resume', { cwd = cwd, threadId = 's9' }, 'resume'),
        resumed,
    })

    local ran, done, statuses = nil, {}, 0
    local au = api.nvim_create_autocmd('User', {
        pattern = { 'BoomerTurnDone', 'BoomerStatus' },
        callback = function(ev)
            if ev.match == 'BoomerTurnDone' then
                done[#done + 1] = ev.data.result
            else
                statuses = statuses + 1
            end
        end,
    })
    local buf = open(scenario, nil, {
        commands = {
            review = { desc = 'Review a file', prompt = 'Review $ARGUMENTS carefully' },
            hi = {
                run = function(args, ctx)
                    ran = args
                    ctx.write('hi from lua')
                end,
            },
        },
    })
    ready(buf)
    assert(state(buf).agent == 'codex' and state(buf).session == 's1')

    -- Unknown commands keep the draft and warn.
    type_draft(buf, '/bogus x')
    enter(buf)
    assert(draft(buf) == '/bogus x', draft(buf))
    assert(notices[#notices]:find('Unknown command /bogus', 1, true), notices[#notices])
    type_draft(buf, '')

    send(buf, '/model m2')
    await(function()
        return has(buf, '[Setting: model = fixture]')
    end, 'model')
    send(buf, '/effort high')
    await(function()
        return has(buf, '[Setting: effort = high]')
    end, 'effort')
    assert(state(buf).model == 'm2')
    send(buf, '//hello')
    turn(buf)
    await(function()
        return #done == 1 and statuses > 0
    end, 'autocmds')
    assert(done[1] == 'completed')
    local bar = winbar(buf)
    assert(bar == 'codex | m2 (high) | ready | ctx 42% | 5h 30%', bar)
    assert(winbar(buf, true) == string.rep(' ', 200 - #bar) .. bar, winbar(buf, true))
    assert(
        boomer.statusline() == 'codex | m2 (high) | ready | ctx 42%% | 5h 30%%',
        boomer.statusline()
    )
    assert(boomer.status().context.size == 100000)

    send(buf, '/usage')
    await(function()
        return has(buf, 'Usage | codex | m2')
    end, 'usage')
    assert(has(buf, 'Context: 42.0k of 100.0k tokens (42%)'), text(buf))
    assert(has(buf, 'Tokens: 1.5k (1.0k in, 500 out)'), text(buf))
    assert(has(buf, '5h limit: 40% used (resets ' .. os.date('%H:%M', resets) .. ')'), text(buf))
    local weekly = os.date('%b %d %H:%M', resets + 2 * 86400)
    assert(has(buf, 'Weekly limit: 12% used (resets ' .. weekly .. ')'), text(buf))
    assert(winbar(buf):find('ctx 42% | 5h 40% | wk 12%', 1, true), winbar(buf))

    send(buf, '/compact')
    await(function()
        return has(buf, '[compacted]') and status(buf, 'ready')
    end, 'compact')
    send(buf, '/review main.lua')
    turn(buf, 2)
    assert(not has(buf, 'Review main.lua carefully'), 'prompt shown instead of the command')
    send(buf, '/hi there')
    assert(ran == 'there' and has(buf, 'hi from lua'))
    send(buf, '/help')
    assert(has(buf, '/review - Review a file') and has(buf, '/hi'), text(buf))
    assert(not has(buf, '/close'), 'Ex-only command listed in the prompt')
    assert(has(buf, '/cancel - Cancel'), text(buf))

    -- Ex commands share the table and echo what they send.
    vim.cmd('Boomer model m1')
    await(function()
        return state(buf).model == 'm1'
    end, 'ex model')
    vim.cmd('Boomer model m2')
    assert(vim.tbl_contains(vim.fn.getcompletion('Boomer ', 'cmdline'), 'cancel'))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer mod', 'cmdline'), { 'mode', 'model' }))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer model ', 'cmdline'), { 'm1', 'm2' }))
    assert(
        vim.deep_equal(vim.fn.getcompletion('Boomer agent c', 'cmdline'), { 'codex', 'copilot' })
    )
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer review ', 'cmdline'), {}))

    send(buf, '/resume s9')
    await(function()
        return state(api.nvim_get_current_buf()).session == 's9'
    end, 'resume')
    assert(not api.nvim_buf_is_valid(buf), 'old buffer kept')
    api.nvim_del_autocmd(au)
    finish()
end)

test('codex permissions', function()
    local base = load('codex-basic')
    local function codex_turn(approval, sandbox)
        local s = steps(base, 6, 9)
        s[1].message.params.approvalPolicy = approval
        s[1].message.params.sandboxPolicy = sandbox
        return s
    end
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 9) }
    vim.list_extend(scenario.steps, codex_turn('on-request', { type = 'readOnly' }))
    vim.list_extend(scenario.steps, codex_turn('never', { type = 'dangerFullAccess' }))
    local buf = open(scenario, nil, {
        winbar = function(st)
            return st.agent .. ' | ' .. (st.permissions or '-')
        end,
    })
    ready(buf)
    -- The fixture's untrusted + full-access sandbox matches no preset.
    assert(winbar(buf) == 'codex | Custom', winbar(buf))
    send(buf)
    turn(buf)
    local values = vim.fn.getcompletion('Boomer permissions ', 'cmdline')
    assert(vim.deep_equal(values, { 'read-only', 'auto', 'full-access' }), vim.inspect(values))

    send(buf, '/permissions read-only')
    await(function()
        return has(buf, '[Setting: permissions = Read Only]')
    end, 'read-only')
    assert(winbar(buf) == 'codex | Read Only', winbar(buf))
    -- statusline() always uses the default layout.
    local line = boomer.statusline()
    assert(vim.startswith(line, 'codex | ') and line:find(' | ready', 1, true), line)
    assert(boomer.status().permissions == 'Read Only')
    send(buf)
    turn(buf, 2)

    vim.ui.select = pick('Full Access')
    send(buf, '/permissions')
    await(function()
        return has(buf, '[Setting: permissions = Full Access]')
    end, 'full access')
    send(buf)
    turn(buf, 3)
    finish()
end)

test('codex modes', function()
    local base = load('codex-basic')
    local function codex_turn(mode, effort)
        local s = steps(base, 6, 9)
        s[1].message.params.collaborationMode = {
            mode = mode,
            settings = {
                model = 'm1',
                reasoning_effort = effort or vim.NIL,
                developer_instructions = vim.NIL,
            },
        }
        return s
    end
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 5) }
    vim.list_extend(scenario.steps, steps(load('codex-models'), 4, 5))
    vim.list_extend(scenario.steps, codex_turn('plan'))
    vim.list_extend(scenario.steps, {
        notify('thread/settings/updated', {
            threadId = 's1',
            threadSettings = {
                model = 'm1',
                effort = 'low',
                collaborationMode = { mode = 'plan' },
            },
        }),
    })
    vim.list_extend(scenario.steps, codex_turn('default', 'low'))
    local buf = open(scenario)
    ready(buf)
    assert(state(buf).mode == nil, vim.inspect(state(buf).mode))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer mode ', 'cmdline'), { 'default', 'plan' }))

    send(buf, '/mode plan')
    await(function()
        return state(buf).mode == 'Plan'
    end, 'plan')
    send(buf)
    turn(buf)
    await(function()
        return state(buf).effort == 'low'
    end, 'settings update')
    assert(state(buf).mode == 'Plan')

    vim.ui.select = pick('Default')
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('<S-Tab>')
    await(function()
        return state(buf).mode == 'Default'
    end, 'default')
    send(buf)
    turn(buf, 2)
    finish()
end)

test('codex defaults', function()
    local base, models = load('codex-basic'), load('codex-models')
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 3) }
    vim.list_extend(scenario.steps, steps(models, 4, 5))
    vim.list_extend(scenario.steps, steps(base, 4))
    scenario.steps[6].message.params.model = 'm2'
    scenario.steps[8].message.params.effort = 'high'
    local buf = open(scenario, nil, { agents = { codex = { model = 'm2', effort = 'HIGH' } } })
    ready(buf)
    send(buf)
    turn(buf)
    finish()

    scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 3) }
    vim.list_extend(scenario.steps, steps(models, 4, 5))
    vim.list_extend(scenario.steps, steps(base, 4, 5))
    buf = open(scenario, nil, { agents = { codex = { model = 'nope', effort = 'max' } } })
    ready(buf)
    assert(has(buf, 'Error: default model: nope is not offered by this agent'), text(buf))
    assert(has(buf, 'Error: default effort: max is not offered by this agent'), text(buf))
    finish()

    scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 9) }
    scenario.steps[6].message.params.collaborationMode = {
        mode = 'plan',
        settings = { model = 'm1', reasoning_effort = vim.NIL, developer_instructions = vim.NIL },
    }
    buf = open(scenario, nil, { agents = { codex = { mode = 'Plan' } } })
    ready(buf)
    assert(state(buf).mode == 'Plan')
    send(buf)
    turn(buf)
    finish()
end)

test('acp slash commands and defaults', function()
    local base = load('acp-basic')
    -- Copilot's mode IDs are URIs.
    local agent_mode = 'https://agentclientprotocol.com/protocol/session-modes#agent'
    local plan_mode = 'https://agentclientprotocol.com/protocol/session-modes#plan'
    local function options(model, effort)
        return {
            {
                id = 'model',
                name = 'Model',
                category = 'model',
                type = 'select',
                currentValue = model,
                options = { { value = 'm1', name = 'One' }, { value = 'm2', name = 'Two' } },
            },
            {
                id = 'reasoning_effort',
                name = 'Effort',
                category = 'thought_level',
                type = 'select',
                currentValue = effort,
                options = { { value = 'low', name = 'low' }, { value = 'high', name = 'high' } },
            },
        }
    end
    local function prompt(text, extra)
        local s = steps(base, 5, 7)
        s[1].message.params.prompt[1].text = text
        if extra then
            table.insert(s, 2, extra)
        end
        return s
    end
    local function update(u)
        return notify('session/update', { sessionId = 's1', update = u })
    end
    local scenario = { version = 1, profile = 'acp-v1', steps = steps(base, 1, 2) }
    vim.list_extend(scenario.steps, {
        expect('session/new', { cwd = cwd, mcpServers = {} }, 'new'),
        -- Copilot advertises commands before answering session/new.
        update({
            sessionUpdate = 'available_commands_update',
            availableCommands = {
                { name = 'plan', description = 'Plan it', input = { hint = 'goal' } },
                { name = 'compact', description = 'Compact' },
                {
                    name = 'permissions',
                    description = 'Switch permission modes',
                    input = { hint = '[default|assisted|allow-all|show]' },
                },
                { name = 'autopilot', input = { hint = '[on|off|<objective>]' } },
            },
        }),
        respond({
            sessionId = 's1',
            configOptions = options('m1', 'low'),
            modes = {
                currentModeId = agent_mode,
                availableModes = {
                    { id = agent_mode, name = 'Agent' },
                    { id = plan_mode, name = 'Plan' },
                },
            },
        }, 'new'),
        expect('session/set_mode', { sessionId = 's1', modeId = plan_mode }),
        respond(vim.empty_dict()),
        expect('session/set_config_option', { sessionId = 's1', configId = 'model', value = 'm2' }),
        respond({ configOptions = options('m2', 'low') }),
        expect(
            'session/set_config_option',
            { sessionId = 's1', configId = 'reasoning_effort', value = 'high' }
        ),
        respond({ configOptions = options('m2', 'high') }),
    })
    vim.list_extend(
        scenario.steps,
        prompt(
            '/plan do it',
            update({
                sessionUpdate = 'usage_update',
                used = 5000,
                size = 10000,
                cost = { amount = 0.25, currency = 'USD' },
            })
        )
    )
    vim.list_extend(scenario.steps, prompt('/compact keep tests'))
    vim.list_extend(scenario.steps, prompt('/permissions allow-all'))
    vim.list_extend(scenario.steps, {
        expect('session/set_mode', { sessionId = 's1', modeId = agent_mode }),
        respond(vim.empty_dict()),
        expect('session/set_mode', { sessionId = 's1', modeId = plan_mode }),
        respond(vim.empty_dict()),
    })
    local buf = open(scenario, 'copilot', {
        agents = { copilot = { model = 'Two', effort = 'high', mode = 'plan' } },
    })
    ready(buf)
    assert(state(buf).model == 'Two', state(buf).model)
    assert(winbar(buf) == 'copilot | Two (high) | Plan | ready', winbar(buf))

    -- Insert-mode completion of commands and their arguments.
    type_draft(buf, '/pl')
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('A<C-x><C-o><Esc>')
    assert(draft(buf) == '/plan', draft(buf))
    type_draft(buf, '/model m')
    keys('A<C-x><C-o><Esc>')
    assert(draft(buf) == '/model m1', draft(buf))
    type_draft(buf, '/mode p')
    keys('A<C-x><C-o><Esc>')
    assert(draft(buf) == '/mode plan', draft(buf))
    -- 'complete' includes the omnifunc, so <C-n> (and 'autocomplete') offer
    -- commands; elsewhere the omnifunc declines and buffer words complete.
    assert(vim.startswith(vim.bo[buf].complete, 'o,'), vim.bo[buf].complete)
    type_draft(buf, '/pl')
    keys('A<C-n><Esc>')
    assert(draft(buf) == '/plan', draft(buf))
    type_draft(buf, 'say Promp')
    keys('A<C-n><Esc>')
    assert(draft(buf) == 'say Prompt', draft(buf))
    type_draft(buf, '')

    send(buf, '/plan do it')
    turn(buf)
    assert(winbar(buf):find('ctx 50% | 0.25 USD', 1, true), winbar(buf))
    send(buf, '/usage')
    assert(has(buf, 'Context: 5.0k of 10.0k tokens (50%)'), text(buf))
    assert(has(buf, 'Cost: 0.25 USD'), text(buf))
    send(buf, '/compact keep tests')
    turn(buf, 2)
    -- /permissions shows, completes and picks the agent's hint choices.
    local values = vim.fn.getcompletion('Boomer permissions ', 'cmdline')
    assert(
        vim.deep_equal(values, { 'default', 'assisted', 'allow-all', 'show' }),
        vim.inspect(values)
    )
    values = vim.fn.getcompletion('Boomer autopilot ', 'cmdline')
    assert(vim.deep_equal(values, { 'on', 'off' }), vim.inspect(values))
    type_draft(buf, '/permissions al')
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('A<C-x><C-o><Esc>')
    assert(draft(buf) == '/permissions allow-all', draft(buf))
    type_draft(buf, '')
    send(buf, '/help')
    assert(has(buf, '/permissions [default|assisted|allow-all|show] - '), text(buf))
    vim.ui.select = pick('allow-all')
    send(buf, '/permissions')
    turn(buf, 3)
    assert(has(buf, 'Prompt: /permissions allow-all'), text(buf))
    send(buf, '/mode agent')
    await(function()
        return state(buf).mode == 'Agent'
    end, 'mode')
    -- <S-Tab> picks the mode, as Copilot's plan mode advises.
    vim.ui.select = function(items, _, cb)
        cb(items[2], 2)
    end
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('<S-Tab>')
    await(function()
        return state(buf).mode == 'Plan'
    end, '<S-Tab> mode')

    -- A picker opened from the prompt keeps Insert mode, like fzf-lua's
    -- terminal expects. With "x!" feedkeys returns once Insert mode ends.
    local mode
    vim.ui.select = function()
        vim.cmd('new')
        vim.cmd.startinsert()
        vim.schedule(function()
            mode = api.nvim_get_mode().mode
            vim.cmd.close()
            api.nvim_input('<Esc>')
        end)
    end
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    type_draft(buf, '/model')
    api.nvim_feedkeys(api.nvim_replace_termcodes('A<CR>', true, false, true), 'xt!', false)
    assert(mode == 'i', 'picker opened in mode ' .. tostring(mode))
    vim.ui.select = function()
        error('unexpected selector')
    end

    -- Switching agents replaces the chat in the same window.
    local first = last
    local win = vim.fn.win_findbuf(buf)[1]
    stage({ version = 1, profile = 'codex-v2', steps = steps(load('codex-basic'), 1, 5) })
    send(buf, '/agent codex')
    await(function()
        return first.exit ~= nil
    end, 'copilot exit')
    assert(first.exit.code == 0, first.stderr)
    local nbuf = api.nvim_win_get_buf(win)
    assert(nbuf ~= buf and not api.nvim_buf_is_valid(buf))
    ready(nbuf)
    assert(state(nbuf).agent == 'codex' and winbar(nbuf):find('^codex'), winbar(nbuf))
    finish()
end)

test('prompt queue', function()
    local base = load('codex-basic')
    -- A Codex turn for `text`, completing after `ms`, or failing with `fail`.
    local function prompt(text, ms, fail)
        local s = steps(base, 6, 9)
        s[1].message.params.input[1].text = text
        table.insert(s, 4, { op = 'delay', ms = ms or 0 })
        if fail then
            s[5].message.params.turn.status = 'failed'
            s[5].message.params.turn.error = { message = fail }
        end
        return s
    end
    local function scenario(start, ...)
        local s = { version = 1, profile = 'codex-v2', steps = start }
        for _, p in ipairs({ ... }) do
            vim.list_extend(s.steps, p)
        end
        return s
    end

    -- Prompts, user `prompt` commands and committed (<C-j>) drafts submitted
    -- during a turn are sent in order, one per turn.
    local buf = open(
        scenario(
            steps(base, 1, 5),
            prompt('hello', 300),
            prompt('q1'),
            prompt('Review x'),
            prompt('q3')
        ),
        nil,
        { commands = { review = { prompt = 'Review $ARGUMENTS' } } }
    )
    send(buf, 'hello')
    await(function()
        return has(buf, 'Agent:\nhello')
    end, 'streamed text')
    type_draft(buf, 'q1')
    enter(buf)
    type_draft(buf, '/review x')
    enter(buf)
    assert(draft(buf) == '' and state(buf).queued == 2, draft(buf))
    assert(virtual(buf) == 'Queued: q1\nQueued: /review x', virtual(buf))
    assert(winbar(buf):find('| running | 2 queued', 1, true), winbar(buf))
    type_draft(buf, 'q3')
    keys('A<C-j><Esc>')
    await(function()
        return has(buf, 'Prompt: q3\n\n[queued]')
    end, 'committed prompt queued; transcript:\n' .. text(buf))
    assert(state(buf).queued == 3)
    type_draft(buf, 'typing')
    turn(buf, 4)
    assert(
        has(
            buf,
            '[queued]\n\n[completed]\n\nPrompt: q1\n\nAgent:\nhello\n\n[completed]\n\n'
                .. 'Prompt: /review x\n\nAgent:\nhello\n\n[completed]\n\n'
                .. 'Agent:\nhello\n\n[completed]\n\nPrompt: typing'
        ),
        text(buf)
    )
    assert(count(buf, 'q3') == 1, 'committed prompt echoed again')
    assert(state(buf).queued == nil and virtual(buf) == '', virtual(buf))
    finish()

    -- CTRL-C returns the queue to the draft, before the typed text; a prompt
    -- queued while cancelling is sent after the cancelled turn.
    local cancel = load('codex-early-cancel')
    buf = open(scenario(cancel.steps, prompt('after')))
    send(buf, 'hello')
    for _, s in ipairs({ 'q1', 'q2\nmore' }) do
        type_draft(buf, s)
        enter(buf)
    end
    assert(virtual(buf) == 'Queued: q1\nQueued: q2 (+1 line)', virtual(buf))
    type_draft(buf, 'typing')
    keys('<C-c>')
    assert(status(buf, 'cancelling'))
    assert(draft(buf) == 'q1\n\nq2\nmore\n\ntyping', draft(buf))
    assert(state(buf).queued == nil and virtual(buf) == '')
    type_draft(buf, 'after')
    enter(buf)
    await(function()
        return has(buf, '[cancelled]\n\nPrompt: after') and count(buf, '[completed]') == 1
    end, 'prompt queued while cancelling; transcript:\n' .. text(buf))
    finish()

    -- /cancel discards the queue and cancels the turn; a prompt queued after
    -- it is sent after the cancelled turn.
    buf = open(scenario(load('codex-early-cancel').steps, prompt('after')))
    send(buf, 'hello')
    for _, s in ipairs({ 'q1', 'q2' }) do
        type_draft(buf, s)
        enter(buf)
    end
    assert(state(buf).queued == 2, 'not queued')
    type_draft(buf, '/cancel')
    enter(buf)
    assert(status(buf, 'cancelling') and draft(buf) == '', draft(buf))
    assert(state(buf).queued == nil and virtual(buf) == '', virtual(buf))
    assert(has(buf, 'Prompt: /cancel\n\n[cancelled 2 queued]'), text(buf))
    type_draft(buf, 'after')
    enter(buf)
    await(function()
        return has(buf, '[cancelled]\n\nPrompt: after') and count(buf, '[completed]') == 1
    end, '/cancel; transcript:\n' .. text(buf))
    assert(not has(buf, 'Prompt: q1') and not has(buf, 'Prompt: q2'), text(buf))
    send(buf, '/cancel')
    assert(notices[#notices] == 'Nothing to cancel', notices[#notices])
    finish()

    -- Prompts queued while the session starts can be taken back with CTRL-C,
    -- or dropped with :Boomer cancel; a failed turn returns the queue to the
    -- draft.
    local start = steps(base, 1, 5)
    table.insert(start, 5, { op = 'delay', ms = 100 })
    buf = open(scenario(start, prompt('hello', 200, 'boom')))
    keys('Aearly<CR><Esc>')
    assert(status(buf, 'starting') and state(buf).queued == 1, 'not queued while starting')
    keys('<C-c>')
    assert(draft(buf) == 'early' and state(buf).queued == nil, draft(buf))
    keys('A<CR><Esc>')
    assert(state(buf).queued == 1, 'not queued again')
    assert(boomer.cancel() and state(buf).queued == nil and draft(buf) == '', draft(buf))
    assert(has(buf, '[cancelled 1 queued]'), text(buf))
    send(buf, 'hello')
    type_draft(buf, 'q1')
    enter(buf)
    await(function()
        return has(buf, 'Error: boom') and status(buf, 'ready')
    end, 'failed turn')
    assert(draft(buf) == 'q1' and state(buf).queued == nil, draft(buf))
    finish()

    -- ACP agent commands are queued too.
    local acp = load('acp-basic')
    local function acp_prompt(text, ms)
        local s = steps(acp, 5, 7)
        s[1].message.params.prompt[1].text = text
        table.insert(s, 3, { op = 'delay', ms = ms or 0 })
        return s
    end
    local s = steps(acp, 1, 3)
    vim.list_extend(s, {
        notify('session/update', {
            sessionId = 's1',
            update = {
                sessionUpdate = 'available_commands_update',
                availableCommands = { { name = 'plan', description = 'Plan it' } },
            },
        }),
    })
    vim.list_extend(s, steps(acp, 4, 4))
    vim.list_extend(s, acp_prompt('hello', 200))
    vim.list_extend(s, acp_prompt('/plan x'))
    buf = open({ version = 1, profile = 'acp-v1', steps = s }, 'copilot')
    send(buf, 'hello')
    type_draft(buf, '/plan x')
    enter(buf)
    assert(virtual(buf) == 'Queued: /plan x', virtual(buf))
    turn(buf, 2)
    assert(has(buf, '[completed]\n\nPrompt: /plan x\n\nAgent:\nhello'), text(buf))
    finish()
end)

test('command queue', function()
    local acp = load('acp-basic')
    local agent_mode = 'https://agentclientprotocol.com/protocol/session-modes#agent'
    local plan_mode = 'https://agentclientprotocol.com/protocol/session-modes#plan'
    local function options(model, effort)
        return {
            {
                id = 'model',
                name = 'Model',
                category = 'model',
                type = 'select',
                currentValue = model,
                options = { { value = 'm1', name = 'One' }, { value = 'm2', name = 'Two' } },
            },
            {
                id = 'reasoning_effort',
                name = 'Effort',
                category = 'thought_level',
                type = 'select',
                currentValue = effort,
                options = { { value = 'low', name = 'low' }, { value = 'high', name = 'high' } },
            },
        }
    end
    -- An ACP turn for `text`, answered after `ms`.
    local function prompt(text, ms)
        local s = steps(acp, 5, 7)
        s[1].message.params.prompt[1].text = text
        table.insert(s, 3, { op = 'delay', ms = ms or 0 })
        return s
    end
    local s = steps(acp, 1, 2)
    vim.list_extend(s, {
        expect('session/new', { cwd = cwd, mcpServers = {} }, 'new'),
        notify('session/update', {
            sessionId = 's1',
            update = {
                sessionUpdate = 'available_commands_update',
                availableCommands = {
                    { name = 'permissions', input = { hint = '[default|allow-all]' } },
                },
            },
        }),
        respond({
            sessionId = 's1',
            configOptions = options('m1', 'low'),
            modes = {
                currentModeId = agent_mode,
                availableModes = {
                    { id = agent_mode, name = 'Agent' },
                    { id = plan_mode, name = 'Plan' },
                },
            },
        }, 'new'),
    })
    vim.list_extend(s, prompt('hello', 300))
    -- Settings change on the agent only once the turn has ended, in order.
    vim.list_extend(s, {
        expect('session/set_config_option', { sessionId = 's1', configId = 'model', value = 'm2' }),
        respond({ configOptions = options('m2', 'low') }),
        expect(
            'session/set_config_option',
            { sessionId = 's1', configId = 'reasoning_effort', value = 'high' }
        ),
        respond({ configOptions = options('m2', 'high') }),
        expect('session/set_mode', { sessionId = 's1', modeId = plan_mode }),
        respond(vim.empty_dict()),
    })
    vim.list_extend(s, prompt('q1'))
    vim.list_extend(s, prompt('/permissions allow-all'))
    vim.list_extend(s, prompt('again', 300))
    vim.list_extend(s, {
        expect('session/set_config_option', { sessionId = 's1', configId = 'model', value = 'm1' }),
        {
            op = 'send_response',
            message = { id = { ref = 'req' }, error = { code = -32000, message = 'nope' } },
        },
    })
    local buf = open({ version = 1, profile = 'acp-v1', steps = s }, 'copilot')
    send(buf, 'hello')
    await(function()
        return has(buf, 'Agent:\nhello')
    end, 'streamed text')

    -- Boomer's commands typed during a turn are queued with prompts; pickers
    -- (/effort, <S-Tab>) open now and queue the choice. The agent's
    -- /permissions is queued as a prompt.
    type_draft(buf, '/model m2')
    enter(buf)
    vim.ui.select = pick('high')
    type_draft(buf, '/effort')
    enter(buf)
    await(function()
        return state(buf).queued == 2
    end, 'picked effort queued')
    vim.ui.select = pick('Plan')
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('<S-Tab>')
    await(function()
        return state(buf).queued == 3
    end, 'picked mode queued')
    vim.ui.select = function()
        error('unexpected selector')
    end
    for _, line in ipairs({ 'q1', '/permissions allow-all' }) do
        type_draft(buf, line)
        enter(buf)
    end
    -- Commands that replace the session still wait for the turn.
    type_draft(buf, '/new')
    enter(buf)
    assert(draft(buf) == '/new', draft(buf))
    assert(notices[#notices]:find('A turn is still active', 1, true), notices[#notices])
    type_draft(buf, '')
    local queued = 'Queued: /model m2\nQueued: /effort high\nQueued: /mode plan\n'
        .. 'Queued: q1\nQueued: /permissions allow-all'
    assert(virtual(buf) == queued, virtual(buf))
    assert(state(buf).model == 'One' and status(buf, 'running'))
    turn(buf, 3)
    assert(
        has(
            buf,
            '[completed]\n\nPrompt: /model m2\n\n[Setting: model = Two]\n\n'
                .. 'Prompt: /effort high\n\n[Setting: reasoning_effort = high]\n\n'
                .. 'Prompt: /mode plan\n\n[Setting: $mode = Plan]\n\n'
                .. 'Prompt: q1\n\nAgent:\nhello\n\n[completed]\n\n'
                .. 'Prompt: /permissions allow-all\n\nAgent:\nhello\n\n[completed]'
        ),
        text(buf)
    )
    assert(state(buf).model == 'Two' and state(buf).mode == 'Plan', vim.inspect(state(buf)))
    assert(state(buf).queued == nil and virtual(buf) == '', virtual(buf))

    -- A committed (<C-j>) command is marked; a failed one returns the rest
    -- of the queue to the draft.
    send(buf, 'again')
    await(function()
        return count(buf, 'Agent:\nhello') == 4
    end, 'streamed text')
    type_draft(buf, '/model One')
    keys('A<C-j><Esc>')
    await(function()
        return has(buf, 'Prompt: /model One\n\n[queued]')
    end, 'committed command queued; transcript:\n' .. text(buf))
    type_draft(buf, 'q2')
    enter(buf)
    assert(virtual(buf) == 'Queued: /model m1\nQueued: q2', virtual(buf))
    await(function()
        return has(buf, 'Error: nope') and draft(buf) == 'q2'
    end, 'failed setting; draft: ' .. draft(buf))
    assert(state(buf).model == 'Two' and state(buf).queued == nil)
    assert(not has(buf, 'Prompt: /model m1'), text(buf))
    finish()

    -- Native Codex compaction is queued as a turn of its own; cancel returns
    -- queued commands to the draft.
    local base = load('codex-basic')
    local function codex_prompt(text, ms)
        local t = steps(base, 6, 9)
        t[1].message.params.input[1].text = text
        table.insert(t, 4, { op = 'delay', ms = ms or 0 })
        return t
    end
    s = steps(base, 1, 5)
    vim.list_extend(s, codex_prompt('hello', 300))
    vim.list_extend(s, {
        expect('thread/compact/start', { threadId = 's1' }),
        respond(vim.empty_dict()),
        notify(
            'turn/started',
            { threadId = 's1', turn = { id = 't2', items = {}, status = 'inProgress' } }
        ),
        notify(
            'turn/completed',
            { threadId = 's1', turn = { id = 't2', items = {}, status = 'completed' } }
        ),
    })
    vim.list_extend(s, codex_prompt('q1'))
    buf = open({ version = 1, profile = 'codex-v2', steps = s })
    send(buf, 'hello')
    for _, line in ipairs({ '/compact', 'q1' }) do
        type_draft(buf, line)
        enter(buf)
    end
    assert(virtual(buf) == 'Queued: /compact\nQueued: q1', virtual(buf))
    turn(buf, 2)
    assert(
        has(buf, '[completed]\n\nPrompt: /compact\n\n[compacted]\n\nPrompt: q1\n\nAgent:\nhello'),
        text(buf)
    )
    finish()

    buf = open(load('codex-early-cancel'))
    send(buf, 'hello')
    type_draft(buf, '/compact')
    enter(buf)
    assert(virtual(buf) == 'Queued: /compact', virtual(buf))
    keys('<C-c>')
    assert(draft(buf) == '/compact', draft(buf))
    await(function()
        return status(buf, 'ready')
    end, 'cancelled')
    assert(not has(buf, '[compacted]'), text(buf))
    finish()
end)

test('rpc framing and failures', function()
    local logged, notified = {}, {}
    local function opts(cmd)
        return {
            cmd = cmd,
            notify = function(method, params)
                notified[#notified + 1] = { method, params }
            end,
            request = function() end,
            log = function(msg)
                logged[#logged + 1] = msg
            end,
            exit = function() end,
        }
    end
    local rpc = assert(Rpc.start(opts({ vim.v.progpath, '--clean', '--headless' })))
    -- A message split across reads is dispatched once complete.
    rpc:feed('{"method":"a","par')
    assert(#notified == 0)
    rpc:feed('ams":{"k":1}}\n\nnot json\n')
    assert(#notified == 1 and notified[1][1] == 'a' and notified[1][2].k == 1)
    assert(logged[1] and logged[1]:find('ignored malformed message: not json', 1, true))

    local errors = {}
    rpc:request('slow', nil, function(err)
        errors.slow = err and err.message
    end, 20)
    await(function()
        return errors.slow
    end, 'timeout')
    assert(errors.slow == 'slow timed out', errors.slow)

    rpc:close()
    rpc:request('late', nil, function(err)
        errors.late = err and err.message
    end)
    await(function()
        return errors.late
    end, 'send after close')
    assert(errors.late == 'agent is not running', errors.late)
    await(function()
        return rpc.exit ~= nil
    end, 'process killed')
    assert(not Rpc.start(opts({ '/missing-boomer-cmd' })), 'spawn failure')
end)

-- An error response to the last captured request.
local function reject(message, ref)
    return {
        op = 'send_response',
        message = { id = { ref = ref or 'req' }, error = { code = -32000, message = message } },
    }
end

local function request(id, method, params)
    return { op = 'send_request', message = { id = id, method = method, params = params } }
end

local function response(id, result, err)
    return { op = 'expect_response', message = { id = id, result = result, error = err } }
end

test('codex protocol edges', function()
    local base = load('codex-basic')
    local function turn_start(text)
        return expect(
            'turn/start',
            { threadId = 's1', input = { { type = 'text', text = text, text_elements = {} } } }
        )
    end
    local function completed(id, status, err)
        return notify('turn/completed', {
            threadId = 's1',
            turn = { id = id, items = {}, status = status, error = err or vim.NIL },
        })
    end
    local amendment = { host = 'example.com', action = 'allow' }
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 5) }
    vim.list_extend(scenario.steps, {
        -- Requests Boomer does not handle, and approvals outside a turn.
        request('u1', 'item/tool/call', { threadId = 's1' }),
        response('u1', nil, { code = -32601, message = 'Method not supported: item/tool/call' }),
        request('a0', 'item/fileChange/requestApproval', { threadId = 's1', itemId = 'x' }),
        response('a0', { decision = 'decline' }),
        {
            op = 'send_notification',
            messages = {
                {
                    method = 'thread/settings/updated',
                    params = { threadId = 's1', threadSettings = { model = 'm9', effort = 'low' } },
                },
                {
                    method = 'thread/name/updated',
                    params = { threadId = 's1', threadName = 'Named' },
                },
                {
                    method = 'item/agentMessage/delta',
                    params = { threadId = 'other', itemId = 'z', delta = 'IGNORED' },
                },
            },
        },
        -- API-key logins have no rate limits.
        expect('account/rateLimits/read', vim.empty_dict()),
        reject('chatgpt authentication required'),
        -- Older servers propose amendments instead of listing decisions.
        turn_start('hello'),
        respond({ turn = { id = 't1', items = {}, status = 'inProgress' } }),
        notify('item/started', {
            threadId = 's1',
            item = { type = 'fileChange', id = 'f1', changes = { { path = 'a.lua' } } },
        }),
        request('g1', 'item/permissions/requestApproval', {
            threadId = 's1',
            itemId = 'g',
            permissions = { network = true },
        }),
        response('g1', { permissions = { network = true }, scope = 'turn' }),
        request('a1', 'item/commandExecution/requestApproval', {
            threadId = 's1',
            itemId = 'c1',
            command = 'curl example.com',
            proposedExecpolicyAmendment = { 'curl' },
            proposedNetworkPolicyAmendments = { amendment },
        }),
        response('a1', {
            decision = { applyNetworkPolicyAmendment = { network_policy_amendment = amendment } },
        }),
        -- The server withdraws a request before it is answered.
        {
            op = 'send_request',
            messages = {
                {
                    id = 'a2',
                    method = 'item/commandExecution/requestApproval',
                    params = { threadId = 's1', itemId = 'c2', command = 'true' },
                },
                {
                    method = 'serverRequest/resolved',
                    params = { threadId = 's1', requestId = 'a2' },
                },
            },
        },
        completed('t1', 'failed', { message = 'boom' }),
        turn_start('again'),
        reject('busy'),
        expect('thread/compact/start', { threadId = 's1' }),
        reject('cannot compact now'),
        expect('model/list', { limit = 100 }),
        reject('offline'),
    })
    local asked = 0
    local function approve(items, opts, cb)
        asked = asked + 1
        local labels = vim.tbl_map(opts.format_item, items)
        if #labels == 2 then
            return pick('Grant for this turn')(items, opts, cb)
        end
        assert(#labels == 6 and labels[1] == 'Deny', vim.inspect(labels))
        pick('applyNetworkPolicyAmendment')(items, opts, cb)
    end
    vim.ui.select = approve
    local buf = open(scenario)
    ready(buf)
    await(function()
        return state(buf).title == 'Named'
    end, 'thread name')
    local st = state(buf)
    assert(st.model == 'm9' and st.effort == 'low', vim.inspect(st))

    -- A failed rate-limit read still writes the usage.
    assert(boomer.usage())
    await(function()
        return has(buf, 'No usage reported yet')
    end, 'usage without rate limits')
    -- Commands that need no agent traffic.
    assert(boomer.resume('s1'), 'resume the current session')
    assert(not boomer.compact('focus'))
    assert(notices[#notices] == 'This agent takes no compaction instructions', notices[#notices])
    boomer.permissions('bogus')
    assert(notices[#notices] == 'Unknown permissions: bogus', notices[#notices])
    vim.ui.select = pick('codex (codex) [current]')
    assert(boomer.agent())
    pause(20)
    assert(state(buf).agent == 'codex' and api.nvim_buf_is_valid(buf), 'same agent replaced')
    vim.ui.select = approve

    send(buf, 'hello')
    await(function()
        return has(buf, 'Error: boom') and status(buf, 'ready')
    end, 'failed turn')
    assert(asked == 2, 'withdrawn request shown: ' .. asked)
    assert(has(buf, 'edit a.lua') and has(buf, 'permissions: {"network":true}'), text(buf))
    assert(has(buf, 'Permission: Run command\ncommand: true'), text(buf))
    assert(not has(buf, 'IGNORED'), 'other thread shown')
    send(buf, 'again')
    await(function()
        return has(buf, 'Error: busy') and status(buf, 'ready')
    end, 'turn/start error')
    send(buf, '/compact')
    await(function()
        return has(buf, 'Error: cannot compact now') and status(buf, 'ready')
    end, 'compact error')
    send(buf, '/model')
    await(function()
        return has(buf, 'Error: offline')
    end, 'model/list error')

    -- A function winbar that fails shows nothing.
    require('boomer.config').options.winbar = function()
        error('bad winbar')
    end
    assert(winbar(buf) == '', winbar(buf))
    finish()

    -- Defaults cannot be checked without the model list; they are sent as is.
    scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 3) }
    vim.list_extend(scenario.steps, { expect('model/list', { limit = 100 }), reject('offline') })
    vim.list_extend(scenario.steps, steps(base, 4, 5))
    scenario.steps[6].message.params.model = 'm2'
    buf = open(scenario, nil, { agents = { codex = { model = 'm2' } } })
    ready(buf)
    assert(has(buf, 'Error: default model and effort not checked: offline'), text(buf))
    finish()
end)

test('acp protocol edges', function()
    local base = load('acp-basic')
    local models = {
        id = 'model',
        name = 'Model',
        category = 'model',
        type = 'select',
        currentValue = 'm1',
        options = { { value = 'm1', name = 'One' }, { value = 'm2', name = 'Two' } },
    }
    local verbose = { id = 'verbose', name = 'Verbose', type = 'boolean', currentValue = false }
    local function update(u)
        return { method = 'session/update', params = { sessionId = 's1', update = u } }
    end
    local function prompt(text)
        return expect(
            'session/prompt',
            { sessionId = 's1', prompt = { { type = 'text', text = text } } }
        )
    end
    local switched = vim.deepcopy(models)
    switched.currentValue = 'm2'
    local scenario = { version = 1, profile = 'acp-v1', steps = steps(base, 1, 2) }
    vim.list_extend(scenario.steps, {
        expect('session/new', { cwd = cwd, mcpServers = {} }),
        respond({
            sessionId = 's1',
            configOptions = { models, verbose },
            modes = {
                currentModeId = 'agent',
                availableModes = {
                    { id = 'agent', name = 'Agent' },
                    { id = 'plan', name = 'Plan' },
                },
            },
        }),
        -- Profile defaults: mode by name (legacy modes), then raw options.
        expect('session/set_mode', { sessionId = 's1', modeId = 'plan' }),
        respond(vim.empty_dict()),
        expect(
            'session/set_config_option',
            { sessionId = 's1', configId = 'verbose', value = true }
        ),
        reject('locked'),
        request('p0', 'session/request_permission', { sessionId = 's1', options = {} }),
        response('p0', { outcome = { outcome = 'cancelled' } }),
        request('f1', 'fs/read_text_file', { sessionId = 's1', path = '/etc/hosts' }),
        response('f1', nil, { code = -32601, message = 'Method not supported: fs/read_text_file' }),
        {
            op = 'send_notification',
            messages = {
                update({ sessionUpdate = 'session_info_update', title = 'Named' }),
                update({ sessionUpdate = 'current_mode_update', currentModeId = 'agent' }),
                update({ sessionUpdate = 'config_option_update', configOptions = { switched } }),
                update({
                    sessionUpdate = 'available_commands_update',
                    availableCommands = { { name = 'plan', description = 'Plan it' } },
                }),
            },
        },
        prompt('hello'),
        respond({
            stopReason = 'end_turn',
            usage = { totalTokens = 300, inputTokens = 200, outputTokens = 100 },
        }),
        prompt('/plan go'),
        respond({ stopReason = 'max_tokens' }),
    })
    local buf = open(scenario, 'copilot', {
        agents = { copilot = { model = 'nope', mode = 'Plan', options = { verbose = true } } },
    })
    ready(buf)
    assert(has(buf, 'Error: default model: nope is not offered by this agent'), text(buf))
    assert(has(buf, 'Error: default verbose: locked'), text(buf))
    await(function()
        local st = state(buf)
        return st.title == 'Named' and st.mode == 'Agent' and st.model == 'Two'
    end, 'session updates')

    send(buf, 'hello')
    turn(buf)
    send(buf, '/usage')
    assert(has(buf, 'Last turn: 300 (200 in, 100 out)'), text(buf))
    -- Agent commands run from Ex are echoed as the user's message.
    vim.cmd('Boomer plan go')
    await(function()
        return has(buf, '[max_tokens]') and status(buf, 'ready')
    end, 'agent command')
    assert(has(buf, 'Prompt: /plan go'), text(buf))

    assert(not boomer.compact())
    assert(notices[#notices] == 'This agent cannot compact the conversation', notices[#notices])
    boomer.resume()
    await(function()
        return notices[#notices] == 'this agent cannot list sessions'
    end, 'list unsupported')
    boomer.resume('s5')
    await(function()
        return status(api.nvim_get_current_buf(), 'failed')
    end, 'load unsupported')
    assert(has(api.nvim_get_current_buf(), 'Error: this agent cannot load sessions'))
    finish()
end)

test('completion fetches what it lacks', function()
    -- Codex lists its models and sessions only on request: completion asks
    -- once in the background and shows the values when they arrive.
    local base = load('codex-basic')
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 5) }
    vim.list_extend(scenario.steps, steps(load('codex-models'), 4, 5))
    vim.list_extend(scenario.steps, steps(load('codex-sessions'), 4, 5))
    local buf = open(scenario)
    ready(buf)
    type_draft(buf, '/model ')
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    -- "x!" keeps Insert mode while scheduled callbacks run; a timer alone
    -- would let headless Neovim read EOF and quit.
    local shown, deadline = nil, vim.uv.hrtime() + 2e9
    local function poll()
        local items = vim.fn.complete_info({ 'items' }).items
        if #items > 0 or vim.uv.hrtime() > deadline then
            shown = vim.tbl_map(function(i)
                return i.word
            end, items)
            api.nvim_input('<C-e><Esc>')
        else
            vim.uv.sleep(5)
            vim.schedule(poll)
        end
    end
    vim.schedule(poll)
    keys('A<C-x><C-o>', '!')
    assert(vim.deep_equal(shown, { 'm1', 'm2' }), vim.inspect(shown))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer effort ', 'cmdline'), { 'high' }))
    type_draft(buf, '')
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer resume ', 'cmdline'), {}))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer resume ', 'cmdline'), {}))
    await(function()
        return #vim.fn.getcompletion('Boomer resume ', 'cmdline') > 0
    end, 'sessions')
    finish()

    -- ACP agents without config options may report legacy session models.
    local acp = load('acp-basic')
    scenario = { version = 1, profile = 'acp-v1', steps = steps(acp, 1, 3) }
    vim.list_extend(scenario.steps, {
        respond({
            sessionId = 's1',
            models = {
                currentModelId = 'a',
                availableModels = {
                    { modelId = 'a', name = 'Alpha' },
                    { modelId = 'b', name = 'Beta' },
                    -- Copilot lists `auto` twice.
                    { modelId = 'a', name = 'Alpha' },
                },
            },
        }, 'new'),
        expect('session/set_model', { sessionId = 's1', modelId = 'b' }),
        respond(vim.empty_dict()),
    })
    buf = open(scenario, 'copilot')
    ready(buf)
    assert(state(buf).model == 'Alpha', state(buf).model)
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer model ', 'cmdline'), { 'a', 'b' }))
    send(buf, '/model Beta')
    await(function()
        return state(buf).model == 'Beta'
    end, 'legacy model')
    finish()
end)

test('user commands and chat edges', function()
    -- Without a chat.
    assert(not boomer.cancel() and notices[#notices] == 'Nothing to cancel')
    assert(not boomer.usage() and notices[#notices] == 'Open a conversation with :Boomer first')
    assert(boomer.help() and vim.bo.filetype == 'help', 'help without a chat')
    vim.cmd.close()
    assert(boomer.omnifunc(1, '') == -3 and vim.deep_equal(boomer.omnifunc(0, '/'), {}))
    assert(boomer.statusline() == '' and boomer.winbar() == '')

    local base = load('codex-basic')
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 9) }
    scenario.steps[6].message.params.input[1].text = 'sent x'
    local buf
    buf = open(scenario, nil, {
        commands = {
            go = {
                run = function(args, ctx)
                    assert(ctx.buf == buf and ctx.status.agent == 'codex')
                    assert(ctx.send('sent ' .. args))
                end,
            },
            bad = {
                run = function()
                    error('oops', 0)
                end,
            },
            empty = {
                prompt = function()
                    return ' '
                end,
            },
            broken = {
                prompt = function()
                    error('nope', 0)
                end,
            },
            files = {
                prompt = 'Read $ARGUMENTS',
                complete = function(st)
                    return { st.agent .. '.lua', 'b.lua' }
                end,
            },
            fixed = { prompt = 'y', complete = { 'one', 'two' } },
        },
    })
    ready(buf)
    assert(not boomer.run('bad') and notices[#notices] == '/bad: oops', notices[#notices])
    assert(not boomer.run('empty') and notices[#notices] == '/empty produced an empty prompt')
    assert(not boomer.run('broken') and notices[#notices] == '/broken: nope', notices[#notices])
    assert(not boomer.run('nope') and notices[#notices]:find('Unknown command /nope', 1, true))
    local files = vim.fn.getcompletion('Boomer files ', 'cmdline')
    assert(vim.deep_equal(files, { 'codex.lua', 'b.lua' }), vim.inspect(files))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer fixed t', 'cmdline'), { 'two' }))

    assert(boomer.run('go x'), notices[#notices])
    turn(buf)
    assert(has(buf, 'Prompt: sent x'), text(buf))
    -- The omnifunc only completes on the prompt line.
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    api.nvim_win_set_cursor(0, { 1, 0 })
    assert(boomer.omnifunc(1, '') == -3)
    finish()
end)

test('VimLeavePre does not wait', function()
    local scenario = load('codex-basic')
    for i = #scenario.steps, 6, -1 do
        scenario.steps[i] = nil
    end
    local buf = open(scenario)
    ready(buf)
    local rpc = last
    local t = vim.uv.hrtime()
    vim.api.nvim_exec_autocmds('VimLeavePre', {})
    assert((vim.uv.hrtime() - t) / 1e6 < 50, 'VimLeavePre blocked')
    await(function()
        return rpc.exit ~= nil
    end, 'agent stopped')
    boomer.close()
end)

local failed = 0
for _, t in ipairs(tests) do
    if not filter or t.name:find(filter, 1, true) then
        local ok, err = xpcall(t.fn, debug.traceback)
        if ok then
            io.stdout:write('ok - ', t.name, '\n')
        else
            failed = failed + 1
            io.stdout:write('not ok - ', t.name, '\n', err, '\n')
            pcall(boomer.close)
            vim.cmd('silent! only')
        end
    end
end
os.exit(failed == 0 and 0 or 1)
