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

local notices, last = {}, nil
vim.notify = function(msg)
    notices[#notices + 1] = msg
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

-- Whether `row` has an extmark whose `field` is `group`. A highlight must
-- cover some text: one collapsed by a line rewrite does not count.
local function marks(buf, row, field, group)
    for _, m in
        ipairs(api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, {
            details = true,
            overlap = true,
        }))
    do
        local d = m[4]
        local empty = field == 'hl_group' and d.end_row == m[2] and d.end_col <= m[3]
        if d[field] == group and not empty then
            return true
        end
    end
    return false
end

-- Whether the transcript has the warning `msg`.
local function warned(buf, msg)
    return has(buf, 'Warning: ' .. msg)
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

-- Text of the live prompt's non-blank virtual lines (the queue); `blanks`
-- keeps the blank ones too, as ''.
local function virtual(buf, blanks)
    local ns = api.nvim_get_namespaces()['boomer.prompt']
    local out = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        for _, line in ipairs(m[4].virt_lines or {}) do
            if #line > 0 then
                out[#out + 1] = line[1][1]
            elseif blanks then
                out[#out + 1] = ''
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

-- A view as the chat creates it, with the configured labels and window.
local function new_view(opts)
    opts = opts or {}
    local options = require('boomer.config').options
    return require('boomer.view').new({
        labels = opts.labels or { user = options.labels.prompt, agent = options.labels.agent },
        signs = options.signs and { user = options.signs.prompt, agent = options.signs.agent },
        window = vim.tbl_deep_extend('force', options.window, opts.window or {}),
    })
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
    assert(not pcall(boomer.setup, { commands = { x = { prompt = print } } }), 'prompt function')
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
    assert(not pcall(boomer.setup, { signs = { prompt = 'abc' } }), 'sign too wide')
    assert(not pcall(boomer.setup, { signs = { user = '|' } }))
    assert(not pcall(boomer.setup, { agents = { codex = { label = '' } } }))
    assert(not pcall(boomer.setup, { diff_lines = 0 }))
    assert(not pcall(boomer.setup, { diff_lines = 1.5 }))
    assert(not pcall(boomer.setup, { diff_lines = true }))

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
    boomer.setup({ signs = { agent = '|' } })
    assert(vim.deep_equal(config.options.signs, { prompt = '▌', agent = '|' }))
    boomer.setup({ signs = false })
    assert(config.options.signs == false)
    boomer.setup({ signs = true })
    assert(config.options.signs.prompt == '▌')
    boomer.setup({
        window = { position = 'float', float = { border = { '+', '-' } } },
        labels = { agent = 'Bot:' },
        winbar = false,
        agents = { copilot = { label = 'Copilot:' } },
    })
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
    assert(commands.expand(spec, 'a.lua') == 'Check a.lua now')
    assert(commands.expand({ prompt = 'Base' }, 'extra') == 'Base\n\nextra')
    assert(commands.expand({ prompt = 'Base' }, '') == 'Base')
    local list = commands.list({ help = false, zed = { prompt = 'z', desc = 'Zed' } }, {
        plan = { name = 'plan', desc = 'Plan it' },
        zed = { name = 'zed' },
    })
    local names = vim.tbl_map(function(i)
        return i.source .. ':' .. i.name
    end, list)
    assert(not vim.tbl_contains(names, 'builtin:help'), 'disabled builtin')
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
    assert(rendered == 'Boomer' .. string.rep(' ', 94 - #st.text(s)) .. st.text(s), rendered)
    assert(bar:find('^%%#BoomerWinbarTitle#Boomer%%#BoomerWinbar#'), bar)
    assert(bar:find('%#BoomerWinbarBusy#running', 1, true), bar)
    -- A narrow window keeps the title and truncates the status from its left.
    rendered = api.nvim_eval_statusline(bar, { use_winbar = true, maxwidth = 20 }).str
    assert(rendered:find('^Boomer <.*0%.50 USD$') and #rendered == 20, rendered)
    assert(
        st.text({ agent = 'x', state = 'exited', context = { used = 1500 } })
            == 'x | exited | ctx 1.5k'
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
    s.tokens = { total = 12345, input = 12000, output = 345 }
    usage = table.concat(st.usage(s), '\n')
    assert(usage:find('Tokens: 12.3k (12.0k in, 345 out)', 1, true), usage)
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
    local view = new_view()
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

    -- A draft Neovim commits itself (keys that bypass the <CR> mapping) is
    -- taken back out; the message written for it starts a block of its own.
    local first = row_of(buf, 'Prompt: draft')
    local committed
    vim.fn.prompt_setcallback(buf, function(s)
        committed = s
        view:uncommit(s)
    end)
    keys('A<CR><Esc>')
    assert(committed == 'draft\nsecond', tostring(committed))
    assert(view:row() == first and view:draft() == '', text(buf))
    view:message('user', committed, 'u2')
    assert(has(buf, 'Agent:\nhello\n\nPrompt: draft\nsecond\nPrompt: '), text(buf))
    assert(marks(buf, first + 1, 'hl_group', 'BoomerUserLabel'))
    local row, col = view:row()
    assert(row == first + 3 and col == #'Prompt: ', 'input mark moved')
    assert(blank(buf) == row, 'blank line did not follow the message')
    assert(marks(buf, row, 'hl_group', 'BoomerUserLabel'), 'label not on the new prompt')

    api.nvim_set_hl(0, 'BoomerUserLabel', { fg = '#234567' })
    vim.cmd.colorscheme('default')
    local user = api.nvim_get_hl(0, { name = 'BoomerUserLabel' })
    assert(user.bold and user.fg == api.nvim_get_hl(0, { name = 'Function', link = false }).fg)
    local agent = api.nvim_get_hl(0, { name = 'BoomerAssistantLabel' })
    assert(agent.bold and agent.fg ~= user.fg, 'roles share a color')
    assert(api.nvim_get_hl(0, { name = 'BoomerUserSign' }).link == 'BoomerUserLabel')
    api.nvim_buf_delete(buf, { force = true })

    -- Custom labels; trailing space on the user label is not doubled.
    view = new_view({ labels = { user = 'Me> ', agent = 'Bot:' } })
    view:message('agent', 'hi')
    view:message('user', 'yo')
    assert(text(view.buf) == 'Bot:\nhi\n\nMe> yo\nMe> ', text(view.buf))
    assert(vim.fn.prompt_getprompt(view.buf) == 'Me> ')
    api.nvim_buf_delete(view.buf, { force = true })
end)

test('gutter signs', function()
    -- Each message's rows, and the draft's, show its role's sign; system lines none.
    local view = new_view()
    local buf = view.buf
    view:open()
    assert(vim.wo.signcolumn == 'no' and vim.wo.statuscolumn ~= '', vim.wo.statuscolumn)
    view:message('user', 'hello\nworld', 'u1')
    view:message('agent', 'Hi', 'a1')
    view:message('agent', ' there\nsecond\n', 'a1')
    view:write('[Tool: ls]')
    view:message('agent', 'done', 'a2')
    view:set_draft('draft\nmore')
    assert(
        text(buf)
            == 'Prompt: hello\nworld\n\nAgent:\nHi there\nsecond\n\n[Tool: ls]\n\n'
                .. 'Agent:\ndone\nPrompt: draft\nmore',
        text(buf)
    )
    local function signs()
        local out = {}
        for row = 0, api.nvim_buf_line_count(buf) - 1 do
            out[#out + 1] = marks(buf, row, 'sign_hl_group', 'BoomerUserSign') and 'U'
                or marks(buf, row, 'sign_hl_group', 'BoomerAssistantSign') and 'A'
                or '.'
        end
        return table.concat(out)
    end
    assert(signs() == 'UU.AAA...AAUU', signs())
    -- Typing in the draft extends its sign.
    keys('Go<Esc>')
    assert(signs() == 'UU.AAA...AAUUU', signs())

    -- The status column draws the sign on every screen row of wrapped lines.
    local win = api.nvim_get_current_win()
    view:message('agent', ' ' .. ('word '):rep(math.floor(api.nvim_win_get_width(win) / 2)), 'a2')
    local lnum = row_of(buf, 'done') + 1
    assert(vim.wo.wrap and #api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] > 100)
    api.nvim_win_set_cursor(win, { lnum, 0 })
    vim.cmd('redraw!')
    local first = vim.fn.screenpos(win, lnum, 1).row
    local last = vim.fn.screenpos(win, lnum, vim.fn.col({ lnum, '$' }) - 1).row
    local col = vim.fn.win_screenpos(win)[2]
    assert(last > first, 'line not wrapped')
    local agent = vim.fn.screenattr(first, col)
    for row = first, last do
        assert(vim.fn.screenstring(row, col) == '▌', 'no sign on screen row ' .. row)
        assert(vim.fn.screenattr(row, col) == agent, 'sign color on screen row ' .. row)
    end
    -- System lines have none; the draft's has the user's color.
    assert(vim.fn.screenstring(vim.fn.screenpos(win, lnum - 3, 1).row, col) == ' ')
    local draft = vim.fn.screenpos(win, lnum + 1, 1).row
    assert(vim.fn.screenstring(draft, col) == '▌' and vim.fn.screenattr(draft, col) ~= agent)
    api.nvim_buf_delete(buf, { force = true })

    boomer.setup({ signs = false })
    view = new_view()
    vim.wo.signcolumn = 'no'
    view:open()
    view:message('agent', 'hi')
    assert(vim.wo.signcolumn == 'no')
    assert(#api.nvim_buf_get_extmarks(view.buf, -1, 0, -1, { details = true, type = 'sign' }) == 0)
    api.nvim_buf_delete(view.buf, { force = true })
    boomer.setup()
end)

test('window layout', function()
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
    local rows = vim.o.lines - vim.o.cmdheight
    local function show(window)
        vim.cmd('silent! only')
        local view = new_view({ window = window })
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
    local view = new_view()
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
    local again = steps(scenario, 8)
    scenario.steps[8].message.params.input[1].text = 'hello\nworld'
    table.insert(scenario.steps, 11, { op = 'delay', ms = 150 })
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
    assert(virtual(buf, true) == '\nQueued: hello (+1 line)', virtual(buf, true))
    -- The queued prompt is sent once the session is ready.
    await(function()
        return status(buf, 'running')
    end, 'queued prompt sent')
    assert(state(buf).queued == nil and virtual(buf) == '', virtual(buf))
    type_draft(buf, ' \n ')
    enter(buf)
    assert(draft(buf) == ' \n ', 'empty prompt was sent')
    keys('A<C-j><Esc>')
    vim.wait(20)
    assert(draft(buf) == ' \n ', 'empty prompt was committed')
    assert(not has(buf, 'Warning: The prompt is empty'), 'empty prompt warned')
    local row = row_of(buf, 'Prompt: hello')
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
    -- Warnings are written into the transcript; one ends a streamed reply.
    local busy = 'Warning: A turn is still active; wait or use /cancel\n\n'
    assert(
        has(
            buf,
            'Prompt: hello\nworld\n\nAgent:\nhello\n\n'
                .. busy
                .. busy
                .. '[completed]\n\nPrompt: keep'
        ),
        text(buf)
    )
    row = row_of(buf, 'Warning: A turn is still active')
    assert(marks(buf, row, 'hl_group', 'BoomerWarning'))

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
    local answers = { 'Two' }
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
    -- /model typed in Insert mode: back to Insert once answered.
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('A/model<CR>', '!')
    await(function()
        return has(buf, '[Setting: model = Two]') and #log == 2
    end, 'setting; log: ' .. vim.inspect(log))
    assert(vim.deep_equal(log, { 'pick i', 'insert' }), vim.inspect(log))
    -- Dismissed.
    log = {}
    keys('A/model<CR>', '!')
    await(function()
        return #log == 2
    end, 'dismissal; log: ' .. vim.inspect(log))
    assert(vim.deep_equal(log, { 'pick i', 'insert' }), vim.inspect(log))
    -- Opened from Normal mode: stays there.
    log = {}
    vim.cmd.stopinsert()
    assert(boomer.model())
    pause(50)
    assert(vim.deep_equal(log, { 'pick n' }), vim.inspect(log))
    -- Answered in the picker's Terminal mode, like fzf-lua: back to Insert
    -- once Normal mode is reached.
    local answer
    vim.ui.select = function(_, _, cb)
        log[#log + 1] = 'pick ' .. api.nvim_get_mode().mode
        vim.cmd.stopinsert()
        answer = cb
    end
    log = {}
    keys('A/model<CR>', '!')
    await(function()
        return answer ~= nil
    end, 'terminal picker')
    local term = api.nvim_create_buf(false, true)
    api.nvim_open_term(term, {})
    local picker = api.nvim_open_win(term, true, { split = 'below' })
    vim.schedule(function()
        log[#log + 1] = 'answer ' .. api.nvim_get_mode().mode
        api.nvim_win_close(picker, true)
        answer(nil)
    end)
    keys('i', '!')
    await(function()
        return #log == 3
    end, 'terminal picker answer; log: ' .. vim.inspect(log))
    assert(vim.deep_equal(log, { 'pick i', 'answer t', 'insert' }), vim.inspect(log))
    assert(api.nvim_get_current_buf() == buf)
    rawset(vim.cmd, 'startinsert', nil)
    finish()

    -- The next permission request, shown once one is answered, returns to
    -- Insert mode after the last one.
    local scenario = load('codex-permission-accept')
    local request, response = vim.deepcopy(scenario.steps[10]), vim.deepcopy(scenario.steps[11])
    request.message.id, response.message.id = 'permission2', 'permission2'
    table.insert(scenario.steps, 11, request)
    table.insert(scenario.steps, 13, response)
    buf = open(scenario)
    ready(buf)
    log = {}
    rawset(vim.cmd, 'startinsert', function(...)
        log[#log + 1] = api.nvim_get_current_buf() == buf and 'insert' or 'elsewhere'
        return startinsert(...)
    end)
    vim.ui.select = function(items, opts, cb)
        log[#log + 1] = 'pick ' .. api.nvim_get_mode().mode
        vim.cmd.stopinsert()
        vim.defer_fn(function()
            pick('Allow once')(items, opts, cb)
        end, 10)
    end
    type_draft(buf, 'hello')
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('A<CR>', '!')
    turn(buf)
    await(function()
        return #log == 3
    end, 'permissions; log: ' .. vim.inspect(log))
    assert(vim.deep_equal(log, { 'pick i', 'pick n', 'insert' }), vim.inspect(log))
    rawset(vim.cmd, 'startinsert', nil)
    finish()
end)

test('acp chat', function()
    -- Unknown requests get -32601; a final response survives an immediate exit.
    local buf = open(load('acp-unknown'), 'copilot')
    send(buf)
    turn(buf)
    assert(count(buf, 'Agent:\nhello') == 1)
    boomer.permissions('auto')
    assert(warned(buf, 'This agent offers no permissions setting'), text(buf))
    finish()

    buf = open(load('acp-final-exit'), 'copilot')
    send(buf)
    await(function()
        return status(buf, 'exited')
    end, 'exit after final response')
    assert(has(buf, 'hello\n\n[completed]'), text(buf))
    assert(has(buf, 'Error: agent exited with code 0'), text(buf))
    assert(not boomer.model(), 'dead chat accepted a command')
    assert(warned(buf, 'The agent has exited; :Boomer restarts it'), text(buf))
    finish()
end)

test('settings', function()
    -- Codex stages settings for the next turn, also while one runs.
    local scenario = load('codex-basic')
    local again = steps(scenario, 8)
    again[1].message.params.model = 'm2'
    vim.list_extend(scenario.steps, again)
    local buf = open(scenario)
    send(buf)
    assert(status(buf, 'running'))
    vim.ui.select = function(items, opts, cb)
        assert(opts.format_item(items[1]):find('[current]', 1, true), 'current not marked')
        cb(items[2])
    end
    assert(boomer.model())
    await(function()
        return has(buf, 'Prompt: /model m2\n\n[Setting: model = ')
    end, 'model during a turn')
    turn(buf)
    send(buf)
    turn(buf, 2)
    assert(not boomer.effort('low'))
    assert(warned(buf, 'Unknown reasoning effort: low'), text(buf))
    finish()

    -- ACP: grouped choices keep their group in the label.
    scenario = load('acp-config')
    local options = scenario.steps[4].message.result.configOptions
    options[1].options = { { name = 'Family', options = options[1].options } }
    buf = open(scenario, 'copilot')
    ready(buf)
    vim.ui.select = pick('Family / Two')
    assert(boomer.model())
    await(function()
        return has(buf, 'Prompt: /model m2\n\n[Setting: model = Family / Two]')
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
    assert(boomer.model())
    pause(20)
    assert(not has(buf, '/model'), 'dismissed picker echoed')
    vim.ui.select = function()
        error('selector failed')
    end
    assert(boomer.model())
    await(function()
        return has(buf, 'selector failed')
    end, 'selector error')
    vim.ui.select = function(items, _, cb)
        cb(items[#items])
    end
    assert(boomer.model())
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
    assert(boomer.model())
    pause(20)
    local stale = late
    assert(boomer.model(), 'a silently closed picker blocks settings')
    pause(20)
    stale()
    pause(20)
    assert(not has(buf, '[Setting:'), 'stale picker answer applied')
    finish()
    late()
    pause(20)

    -- A setting answered after /new opened another session changes nothing.
    scenario = load('acp-config')
    local base = vim.deepcopy(scenario.steps)
    scenario.steps = { base[1], base[2], base[3], base[4], base[5], { op = 'delay', ms = 100 } }
    vim.list_extend(scenario.steps, { base[6], base[3], vim.deepcopy(base[4]) })
    scenario.steps[9].message.result.sessionId = 's2'
    buf = open(scenario, 'copilot')
    ready(buf)
    assert(boomer.model('m2'))
    pause(20)
    assert(boomer.new())
    local fresh
    await(function()
        fresh = api.nvim_get_current_buf()
        return fresh ~= buf and status(fresh, 'ready') and state(fresh).session == 's2'
    end, 'new session')
    pause(50)
    assert(not has(fresh, '[Setting:'), text(fresh))
    assert(state(fresh).model == 'One', state(fresh).model)
    finish()
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
    scenario.steps[10].message.params.availableDecisions = { 'decline', decision }
    scenario.steps[11].message.result.decision = decision
    vim.ui.select = pick('Policy change:')
    local buf = open(scenario)
    send(buf)
    turn(buf)
    finish()
end)

test('permission queue and cancel', function()
    -- Two simultaneous requests open one selector at a time.
    local scenario = load('codex-permission-accept')
    local request, response = vim.deepcopy(scenario.steps[10]), vim.deepcopy(scenario.steps[11])
    request.message.id, response.message.id = 'permission2', 'permission2'
    table.insert(scenario.steps, 11, request)
    table.insert(scenario.steps, 13, response)
    local open_selectors = {}
    local function defer(items, _, cb)
        open_selectors[#open_selectors + 1] = function()
            cb(items[2])
        end
    end
    vim.ui.select = defer
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

    -- A request the server resolves while shown lets the next one show.
    scenario = load('codex-permission-accept')
    request = vim.deepcopy(scenario.steps[10])
    response = vim.deepcopy(scenario.steps[11])
    request.message.id, response.message.id = 'permission2', 'permission2'
    scenario.steps[11] = request
    table.insert(scenario.steps, 12, response)
    table.insert(scenario.steps, 12, {
        op = 'send_notification',
        message = {
            method = 'serverRequest/resolved',
            params = { threadId = 's1', requestId = 'permission1' },
        },
    })
    -- The first picker is open when its request is resolved.
    table.insert(scenario.steps, 12, { op = 'delay', ms = 100 })
    open_selectors = {}
    vim.ui.select = defer
    buf = open(scenario)
    send(buf)
    await(function()
        return #open_selectors == 2
    end, 'selector after resolved request')
    open_selectors[2]()
    turn(buf)
    open_selectors[1]()
    pause(30)
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
    table.insert(scenario.steps, 10, {
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
    scenario.steps[12].message.result = nil
    scenario.steps[12].message.error = { code = -1, message = 'no' }
    table.insert(scenario.steps, 13, vim.deepcopy(scenario.steps[11]))
    table.insert(
        scenario.steps,
        14,
        { op = 'send_response', message = { id = { ref = 'interrupt' }, result = {} } }
    )
    buf = open(scenario)
    send(buf)
    -- Errors are notified too while the chat is hidden.
    vim.cmd('close')
    boomer.cancel()
    await(function()
        return has(buf, 'Error: cancel failed: no') and status(buf, 'running')
    end, 'cancel failure')
    assert(notices[#notices] == 'cancel failed: no', notices[#notices])
    assert(boomer.cancel())
    await(function()
        return has(buf, '[cancelled]') and status(buf, 'ready')
    end, 'retried cancel')
    finish()

    -- An agent that never answers: closing mid-turn ends the turn.
    buf = open(load('acp-hang'), 'copilot')
    send(buf)
    assert(boomer.cancel())
    pause(50)
    assert(status(buf, 'cancelling'))
    finish()
end)

test('process failures', function()
    -- Exit reports the code and stderr; the draft survives.
    local scenario = load('codex-basic')
    for i = #scenario.steps, 8, -1 do
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
        return status(buf, 'exited')
    end, 'disconnect')
    assert(has(buf, 'Error: agent exited with code 3:\nboom'), text(buf))
    assert(draft(buf) == 'keep')
    enter(buf)
    assert(draft(buf) == 'keep', 'dead chat accepted a prompt')
    assert(warned(buf, 'The agent has exited; :Boomer restarts it'), text(buf))
    assert(last.exit.code == 3, last.stderr)
    -- :Boomer restarts it in the same window, with the draft.
    stage(load('codex-basic'))
    local win = vim.fn.win_findbuf(buf)[1]
    local new = boomer.open()
    assert(new ~= buf and not api.nvim_buf_is_valid(buf), 'not restarted')
    assert(api.nvim_win_get_buf(win) == new and draft(new) == 'keep', draft(new))
    type_draft(new, '')
    send(new)
    turn(new)
    finish()

    -- Startup failures leave an inspectable buffer.
    buf = open(load('acp-exit'), 'copilot')
    await(function()
        return status(buf, 'exited')
    end, 'startup exit')
    assert(count(buf, 'Error:') == 1, 'exit error repeated: ' .. text(buf))
    finish(7)
    buf = open(load('acp-auth'), 'copilot')
    await(function()
        return status(buf, 'no session')
    end, 'session error')
    assert(has(buf, 'Error: Authentication required'))
    boomer.close()
    buf = open(load('acp-version'), 'copilot')
    await(function()
        return status(buf, 'exited')
    end, 'version error')
    assert(has(buf, 'Error: unsupported ACP version'), text(buf))
    boomer.close()
    boomer.setup({
        agents = { codex = { command = '/missing-boomer-test-executable' } },
    })
    buf = boomer.open()
    assert(status(buf, 'exited') and has(buf, 'Error:'), text(buf))
    -- An agent that exited can be restarted or replaced.
    assert(boomer.agent('codex'))
    assert(not api.nvim_buf_is_valid(buf))
    buf = api.nvim_get_current_buf()
    assert(status(buf, 'exited') and state(buf).agent == 'codex', text(buf))
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
    for i = #scenario.steps, 8, -1 do
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
    play({ version = 1, profile = 'codex-v2', steps = steps(list, 1, nil, resume, 6) }, 'codex')
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
    play({ version = 1, profile = 'codex-v2', steps = steps(list, 1, 7, basic, 6, 7) })
    vim.ui.select = function(_, _, cb)
        cb(nil)
    end
    boomer.resume()
    ready(api.nvim_get_current_buf())
    finish()

    -- A picker closed without an answer leaves a usable chat with no session.
    play({ version = 1, profile = 'codex-v2', steps = steps(list, 1, 7, basic, 6, 7) })
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
    -- Options reported while replaying are kept; the load result has none.
    table.insert(load_steps[2].messages, {
        method = 'session/update',
        params = {
            sessionId = 's1',
            update = {
                sessionUpdate = 'config_option_update',
                configOptions = {
                    {
                        id = 'model',
                        name = 'Model',
                        category = 'model',
                        type = 'select',
                        currentValue = 'm1',
                        options = { { value = 'm1', name = 'One' } },
                    },
                },
            },
        },
    })
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
    -- The draft moves to the new buffer.
    type_draft(old, 'draft')
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
    assert(has(buf, '\n\n[Session: Saved chat 1]\n\nPrompt: draft'), text(buf))
    assert(state(buf).model == 'One', vim.inspect(state(buf).model))
    type_draft(buf, '')
    send(buf)
    turn(buf)
    assert(boomer.new())
    local fresh = api.nvim_get_current_buf()
    assert(fresh ~= buf and not api.nvim_buf_is_valid(buf))
    ready(fresh)
    assert(text(fresh) == '[Session: new]\n\nPrompt: ', text(fresh))
    assert(state(fresh).session == 's3' and last == rpc, 'switch started a new process')
    finish()

    -- A failed load is reported in the new buffer and the chat stays usable.
    local refused = load('codex-resume-error')
    refused.steps[6].message.params.threadId = 's2'
    scenario = {
        version = 1,
        profile = 'codex-v2',
        steps = steps(basic, 1, 7, list, 6, 7, refused, 6, 7, basic, 6, 7),
    }
    old = open(scenario)
    ready(old)
    vim.ui.select = pick('Saved chat 2')
    boomer.resume()
    await(function()
        return status(api.nvim_get_current_buf(), 'no session')
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
        steps = steps(basic, 1, 7, load('codex-sessions-error'), 6, 7),
    }
    buf = open(scenario)
    ready(buf)
    boomer.resume()
    await(function()
        return warned(buf, 'session list refused')
    end, 'list error')
    assert(api.nvim_buf_is_valid(buf) and status(buf, 'ready'))
    finish()
end)

test('sessions follow the working directory', function()
    -- The agent keeps running where it started; /resume and /new use the
    -- directory Neovim has now.
    local dir = vim.fs.joinpath(cwd, 'boomer-cwd-test')
    vim.fn.mkdir(dir, 'p')
    vim.fn.chdir(dir)
    local there = require('boomer.config').cwd()
    vim.fn.chdir(cwd)
    local function body()
        local list = steps(load('acp-sessions'), 3)
        local resumed = steps(load('acp-resume-replay'), 3, 5)
        list[1].message.params.cwd = there
        resumed[1].message.params.cwd = there
        local scenario = {
            version = 1,
            profile = 'acp-v1',
            steps = steps(load('acp-sessions'), 1, 2),
        }
        vim.list_extend(scenario.steps, steps(load('acp-basic'), 3, 4))
        scenario.steps[4].message.result.sessionId = 's0'
        vim.list_extend(scenario.steps, list)
        vim.list_extend(scenario.steps, resumed)
        local old = open(scenario, 'copilot')
        ready(old)
        assert(state(old).cwd == cwd, vim.inspect(state(old).cwd))
        vim.fn.chdir(there)
        local prompt
        vim.ui.select = function(items, opts, cb)
            prompt = opts.prompt
            cb(items[2])
        end
        assert(boomer.resume())
        await(function()
            return not api.nvim_buf_is_valid(old)
        end, 'old buffer wiped')
        local buf = api.nvim_get_current_buf()
        ready(buf)
        assert(prompt == 'Boomer sessions (copilot | ' .. there .. '):', prompt)
        assert(state(buf).session == 's1' and state(buf).cwd == there, vim.inspect(state(buf)))
        finish()

        -- /new on a running Codex agent starts the thread in the new directory.
        vim.fn.chdir(cwd)
        local basic = load('codex-basic')
        local started = steps(load('codex-basic'), 6, 7)
        started[1].message.params.cwd = there
        started[2].message.result.cwd = there
        scenario = { version = 1, profile = 'codex-v2', steps = steps(basic, 1, 7) }
        vim.list_extend(scenario.steps, started)
        old = open(scenario)
        ready(old)
        local rpc = last
        vim.fn.chdir(there)
        assert(boomer.new())
        buf = api.nvim_get_current_buf()
        assert(buf ~= old)
        ready(buf)
        assert(state(buf).cwd == there and last == rpc, vim.inspect(state(buf)))
        finish()

        -- /resume that starts the agent lists where it ran, even after a :cd
        -- while the agent was starting.
        vim.fn.chdir(cwd)
        play({
            version = 1,
            profile = 'codex-v2',
            steps = steps(load('codex-sessions'), 1, 7, basic, 6, 7),
        })
        vim.ui.select = function(_, _, cb)
            cb(nil)
        end
        boomer.resume()
        vim.fn.chdir(there)
        buf = api.nvim_get_current_buf()
        ready(buf)
        assert(state(buf).cwd == cwd, vim.inspect(state(buf)))
        finish()
    end
    local ok, err = pcall(body)
    vim.fn.chdir(cwd)
    vim.fn.delete(dir, 'd')
    if not ok then
        error(err, 0)
    end
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

-- Evaluate the chat window's winbar as Neovim draws it; unless `padded`, without
-- the default winbar's "Boomer" title and the gap after it.
local function winbar(buf, padded)
    local win = vim.fn.win_findbuf(buf)[1]
    vim.g.statusline_winid = win
    -- Wide enough not to truncate in the narrow test window.
    local opts = { winid = win, use_winbar = true, maxwidth = 200 }
    local s = api.nvim_eval_statusline(vim.wo[win].winbar, opts).str
    vim.g.statusline_winid = nil
    return padded and s or (s:gsub('^Boomer +', ''):gsub('^ +', ''))
end

test('codex slash commands', function()
    local base = load('codex-basic')
    local function codex_turn(text, extra)
        local s = steps(base, 8, 11)
        s[1].message.params.input[1].text = text
        s[1].message.params.model, s[1].message.params.effort = 'm2', 'high'
        if extra then
            table.insert(s, 4, extra)
        end
        return s
    end
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 7) }
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
    local resumed = vim.deepcopy(base.steps[7])
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
    assert(warned(buf, 'Unknown command /bogus'), text(buf))
    local tail = 'as text\n\nPrompt: /bogus x'
    assert(text(buf):sub(-#tail) == tail, text(buf))
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
    assert(winbar(buf, true) == 'Boomer' .. string.rep(' ', 194 - #bar) .. bar, winbar(buf, true))
    assert(
        boomer.statusline() == 'codex | m2 (high) | ready | ctx 42%% | 5h 30%%',
        boomer.statusline()
    )
    assert(boomer.status().context.size == 100000)

    send(buf, '/usage')
    await(function()
        return has(buf, 'Usage | codex | m2')
    end, 'usage')
    assert(count(buf, '/usage') == 1 and has(buf, 'Prompt: /usage\n\nUsage |'), text(buf))
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
    assert(ran == 'there' and has(buf, 'Prompt: /hi there\n\nhi from lua'), text(buf))
    send(buf, '/help')
    assert(has(buf, '/review - Review a file') and has(buf, '/hi'), text(buf))
    assert(has(buf, '/close - Stop the agent'), text(buf))
    assert(has(buf, '/cancel - Cancel'), text(buf))
    assert(count(buf, 'Prompt: /help') == 1, 'typed /help echoed again')

    -- Commands without arguments reject them; a typed draft stays editable.
    type_draft(buf, '/new foo')
    enter(buf)
    assert(draft(buf) == '/new foo' and warned(buf, '/new takes no arguments'), text(buf))
    type_draft(buf, '')
    vim.cmd('Boomer /usage x')
    assert(warned(buf, '/usage takes no arguments') and count(buf, 'Usage |') == 1, text(buf))

    -- Ex commands share the table and echo what they send.
    vim.cmd('Boomer /model m1')
    await(function()
        return state(buf).model == 'm1'
    end, 'ex model')
    vim.cmd('Boomer /model m2')
    assert(vim.tbl_contains(vim.fn.getcompletion('Boomer ', 'cmdline'), '/cancel'))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer /mod', 'cmdline'), { '/mode', '/model' }))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer /model ', 'cmdline'), { 'm1', 'm2' }))
    assert(
        vim.deep_equal(vim.fn.getcompletion('Boomer /agent c', 'cmdline'), { 'codex', 'copilot' })
    )
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer /review ', 'cmdline'), {}))

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
        local s = steps(base, 8, 11)
        s[1].message.params.approvalPolicy = approval
        s[1].message.params.sandboxPolicy = sandbox
        return s
    end
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 11) }
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
    local values = vim.fn.getcompletion('Boomer /permissions ', 'cmdline')
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
    local function codex_turn(mode, effort, model)
        local s = steps(base, 8, 11)
        s[1].message.params.model = model
        s[1].message.params.collaborationMode = {
            mode = mode,
            settings = {
                model = model or 'm1',
                reasoning_effort = effort or vim.NIL,
                developer_instructions = vim.NIL,
            },
        }
        return s
    end
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 7) }
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
    -- m2 does not offer the thread's effort, so the mode gets none.
    vim.list_extend(scenario.steps, codex_turn('default', nil, 'm2'))
    local buf = open(scenario)
    ready(buf)
    assert(state(buf).mode == nil, vim.inspect(state(buf).mode))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer /mode ', 'cmdline'), { 'default', 'plan' }))

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

    -- <S-Tab> switches to the next mode, wrapping around.
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('<S-Tab>')
    await(function()
        return state(buf).mode == 'Default'
    end, 'default')
    assert(has(buf, 'Prompt: /mode default\n\n[Setting: mode = Default]'), text(buf))
    send(buf)
    turn(buf, 2)
    send(buf, '/model m2')
    send(buf)
    turn(buf, 3)
    finish()
end)

test('codex defaults', function()
    local base = load('codex-basic')
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1) }
    scenario.steps[6].message.params.model = 'm2'
    scenario.steps[8].message.params.effort = 'high'
    local buf = open(scenario, nil, { agents = { codex = { model = 'm2', effort = 'HIGH' } } })
    ready(buf)
    send(buf)
    turn(buf)
    finish()

    scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 7) }
    buf = open(scenario, nil, { agents = { codex = { model = 'nope', effort = 'max' } } })
    ready(buf)
    assert(has(buf, 'Error: default model: nope is not offered by this agent'), text(buf))
    assert(has(buf, 'Error: default effort: max is not offered by this agent'), text(buf))
    finish()

    scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 11) }
    scenario.steps[8].message.params.collaborationMode = {
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
                -- Only m2 offers high: the effort default waits for the model.
                options = model == 'm2'
                        and { { value = 'low', name = 'low' }, { value = 'high', name = 'high' } }
                    or { { value = 'low', name = 'low' } },
            },
            -- Copilot reports an on/off option in the permissions category.
            {
                id = 'allow_all',
                name = 'Allow all',
                category = 'permissions',
                type = 'boolean',
                currentValue = false,
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
    local values = vim.fn.getcompletion('Boomer /permissions ', 'cmdline')
    assert(
        vim.deep_equal(values, { 'default', 'assisted', 'allow-all', 'show' }),
        vim.inspect(values)
    )
    values = vim.fn.getcompletion('Boomer /autopilot ', 'cmdline')
    assert(vim.deep_equal(values, { 'on', 'off' }), vim.inspect(values))
    type_draft(buf, '/permissions al')
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('A<C-x><C-o><Esc>')
    assert(draft(buf) == '/permissions allow-all', draft(buf))
    type_draft(buf, '')
    -- The agent's own /permissions wins over its permissions option: the
    -- picker offers the presets in its hint.
    local offered
    vim.ui.select = function(items, opts, cb)
        offered = vim.tbl_map(opts.format_item, items)
        pick('allow-all')(items, opts, cb)
    end
    assert(boomer.permissions())
    turn(buf, 3)
    assert(
        vim.deep_equal(offered, { 'default', 'assisted', 'allow-all', 'show' }),
        vim.inspect(offered)
    )
    assert(has(buf, 'Prompt: /permissions allow-all'), text(buf))
    send(buf, '/mode agent')
    await(function()
        return state(buf).mode == 'Agent'
    end, 'mode')
    -- <S-Tab> switches to the next mode, as Copilot's plan mode advises.
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
    stage({ version = 1, profile = 'codex-v2', steps = steps(load('codex-basic'), 1, 7) })
    send(buf, '/agent codex')
    await(function()
        return first.exit ~= nil
    end, 'copilot exit')
    assert(first.exit.code == 0, first.stderr)
    local nbuf = api.nvim_win_get_buf(win)
    assert(nbuf ~= buf and not api.nvim_buf_is_valid(buf))
    ready(nbuf)
    assert(state(nbuf).agent == 'codex' and winbar(nbuf):find('^codex'), winbar(nbuf))
    assert(text(nbuf) == '[Agent: codex]\n\nPrompt: ', text(nbuf))
    finish()
end)

test('prompt queue', function()
    local base = load('codex-basic')
    -- A Codex turn for `text`, completing after `ms`, or failing with `fail`.
    local function prompt(text, ms, fail)
        local s = steps(base, 8, 11)
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
    -- during a turn are sent in order, one per turn, and shown when sent.
    local buf = open(
        scenario(
            steps(base, 1, 7),
            prompt('hello', 300),
            prompt('q1'),
            prompt('Review x'),
            prompt('q3')
        ),
        nil,
        { commands = { review = { prompt = 'Review $ARGUMENTS' } } }
    )
    -- A committed command that cannot run returns to the draft, after its
    -- warning.
    ready(buf)
    type_draft(buf, '/cancel')
    keys('A<C-j><Esc>')
    await(function()
        return draft(buf) == '/cancel'
    end, 'committed draft restored; transcript:\n' .. text(buf))
    assert(text(buf) == 'Warning: Nothing to cancel\n\nPrompt: /cancel', text(buf))
    type_draft(buf, '')
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
    assert(virtual(buf, true):find('Queued: /review x\n$'), 'no blank line above the prompt')
    assert(winbar(buf):find('| running | 2 queued', 1, true), winbar(buf))
    -- The live prompt is grayed out while the turn runs.
    local function prompt_hl(field, group)
        return marks(buf, api.nvim_buf_get_mark(buf, ':')[1] - 1, field, group)
    end
    assert(prompt_hl('hl_group', 'BoomerPromptBusy'), 'prompt label not busy')
    assert(prompt_hl('sign_hl_group', 'BoomerPromptBusy'), 'prompt sign not busy')
    assert(not prompt_hl('hl_group', 'BoomerUserLabel'))
    assert(not has(buf, 'q1'), 'queued prompt shown before it was sent')
    type_draft(buf, 'q3')
    keys('A<C-j><Esc>')
    await(function()
        return state(buf).queued == 3
    end, 'committed prompt queued; transcript:\n' .. text(buf))
    assert(not has(buf, 'q3'), 'committed prompt left in the transcript')
    -- So is the text being typed, through its last line.
    local function draft_hl()
        local row, col = unpack(api.nvim_buf_get_mark(buf, ':'))
        local last = api.nvim_buf_line_count(buf) - 1
        local len = #api.nvim_buf_get_lines(buf, last, last + 1, false)[1]
        for _, m in ipairs(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
            local d = m[4]
            if
                d.hl_group == 'BoomerPromptBusy'
                and m[2] == row - 1
                and m[3] == col
                and d.end_row == last
                and d.end_col == len
            then
                return true
            end
        end
        return false
    end
    type_draft(buf, 'typing\nmore')
    assert(draft_hl(), 'draft not busy')
    type_draft(buf, 'typing')
    assert(draft_hl(), 'draft not busy')
    turn(buf, 4)
    assert(
        has(
            buf,
            'Agent:\nhello\n\n[completed]\n\nPrompt: q1\n\nAgent:\nhello\n\n[completed]\n\n'
                .. 'Prompt: /review x\n\nAgent:\nhello\n\n[completed]\n\n'
                .. 'Prompt: q3\n\nAgent:\nhello\n\n[completed]\n\nPrompt: typing'
        ),
        text(buf)
    )
    assert(state(buf).queued == nil and virtual(buf) == '', virtual(buf))
    assert(prompt_hl('hl_group', 'BoomerUserLabel'), 'prompt label still busy')
    assert(prompt_hl('sign_hl_group', 'BoomerUserSign'), 'prompt sign still busy')
    assert(not draft_hl(), 'draft still busy')
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

    -- /cancel does the same.
    buf = open(scenario(load('codex-early-cancel').steps, prompt('after')))
    send(buf, 'hello')
    for _, s in ipairs({ 'q1', 'q2' }) do
        type_draft(buf, s)
        enter(buf)
    end
    assert(state(buf).queued == 2, 'not queued')
    type_draft(buf, '/cancel')
    enter(buf)
    assert(status(buf, 'cancelling') and draft(buf) == 'q1\n\nq2', draft(buf))
    assert(state(buf).queued == nil and virtual(buf) == '', virtual(buf))
    type_draft(buf, 'after')
    enter(buf)
    await(function()
        return has(buf, 'Prompt: /cancel\n\n[cancelled]\n\nPrompt: after')
            and count(buf, '[completed]') == 1
    end, '/cancel; transcript:\n' .. text(buf))
    send(buf, '/cancel')
    local tail = 'Warning: Nothing to cancel\n\nPrompt: /cancel'
    assert(text(buf):sub(-#tail) == tail, text(buf))
    type_draft(buf, '')
    finish()

    -- Prompts queued while the session starts can be taken back with CTRL-C
    -- or :Boomer cancel; a failed turn returns the queue to the draft.
    local start = steps(base, 1, 7)
    table.insert(start, 7, { op = 'delay', ms = 100 })
    buf = open(scenario(start, prompt('hello', 200, 'boom')))
    keys('Aearly<CR><Esc>')
    assert(status(buf, 'starting') and state(buf).queued == 1, 'not queued while starting')
    keys('<C-c>')
    assert(draft(buf) == 'early' and state(buf).queued == nil, draft(buf))
    keys('A<CR><Esc>')
    assert(state(buf).queued == 1, 'not queued again')
    assert(boomer.cancel() and state(buf).queued == nil and draft(buf) == 'early', draft(buf))
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

test('send now', function()
    -- Normal-mode <S-CR> sends the draft ahead of the queue, interrupting the
    -- turn; the rest of the queue follows. So does a user command's send(),
    -- also while the turn is being cancelled.
    local base = load('codex-basic')
    local function prompt(text)
        local s = steps(base, 8, 11)
        s[1].message.params.input[1].text = text
        return s
    end
    local s = load('codex-early-cancel')
    for _, p in ipairs({ 'soon', 'now', 'q1' }) do
        vim.list_extend(s.steps, prompt(p))
    end
    local buf = open(s, nil, {
        commands = {
            go = {
                run = function(args, ctx)
                    ctx.send(args)
                end,
            },
        },
    })
    send(buf, 'hello')
    type_draft(buf, 'q1')
    enter(buf)
    type_draft(buf, 'now')
    keys('<S-CR>')
    assert(status(buf, 'cancelling') and draft(buf) == '', draft(buf))
    type_draft(buf, '/go soon')
    keys('<S-CR>')
    assert(virtual(buf) == 'Queued: soon\nQueued: now\nQueued: q1', virtual(buf))
    turn(buf, 3)
    assert(
        has(
            buf,
            '[cancelled]\n\nPrompt: soon\n\nAgent:\nhello\n\n[completed]\n\n'
                .. 'Prompt: now\n\nAgent:\nhello\n\n[completed]\n\n'
                .. 'Prompt: q1\n\nAgent:\nhello\n\n[completed]'
        ),
        text(buf)
    )
    finish()

    -- While the session starts, it goes ahead of the queue; there is no turn
    -- to interrupt.
    s = steps(base, 1, 7)
    table.insert(s, 7, { op = 'delay', ms = 100 })
    vim.list_extend(s, prompt('now'))
    vim.list_extend(s, prompt('q1'))
    buf = open({ version = 1, profile = 'codex-v2', steps = s })
    keys('Aq1<CR><Esc>')
    type_draft(buf, 'now')
    keys('<S-CR>')
    assert(status(buf, 'starting'), 'not starting')
    assert(virtual(buf) == 'Queued: now\nQueued: q1', virtual(buf))
    turn(buf, 2)
    assert(not has(buf, '[cancelled]'), text(buf))
    assert(has(buf, 'Prompt: now\n\nAgent:\nhello\n\n[completed]\n\nPrompt: q1'), text(buf))
    finish()

    -- An agent's /permissions goes ahead too, also once chosen in a picker; a
    -- blank draft interrupts the turn for the next queued prompt, or warns
    -- without one.
    local acp = load('acp-basic')
    local function acp_prompt(text, cancelled)
        local t = steps(acp, 5, 7)
        t[1].message.params.prompt[1].text = text
        if cancelled then
            t[3].message.result.stopReason = 'cancelled'
            table.insert(t, 3, {
                op = 'expect_notification',
                message = { method = 'session/cancel', params = { sessionId = 's1' } },
            })
        end
        return t
    end
    local a = steps(acp, 1, 3)
    table.insert(
        a,
        notify('session/update', {
            sessionId = 's1',
            update = {
                sessionUpdate = 'available_commands_update',
                availableCommands = {
                    { name = 'permissions', input = { hint = '[default|allow-all]' } },
                },
            },
        })
    )
    vim.list_extend(a, steps(acp, 4, 4))
    vim.list_extend(a, acp_prompt('hello', true))
    vim.list_extend(a, acp_prompt('/permissions allow-all', true))
    vim.list_extend(a, acp_prompt('q1'))
    buf = open({ version = 1, profile = 'acp-v1', steps = a }, 'copilot')
    send(buf, 'hello')
    await(function()
        return has(buf, 'Agent:\nhello')
    end, 'streamed text')
    vim.ui.select = function(items, _, cb)
        assert(items[2] == 'allow-all', vim.inspect(items))
        cb(items[2])
    end
    type_draft(buf, '/permissions')
    keys('<S-CR>')
    await(function()
        return has(buf, '[cancelled]\n\nPrompt: /permissions allow-all\n\nAgent:\nhello')
    end, '/permissions sent now; transcript:\n' .. text(buf))
    type_draft(buf, 'q1')
    enter(buf)
    assert(virtual(buf) == 'Queued: q1', virtual(buf))
    type_draft(buf, '')
    keys('<S-CR>')
    turn(buf, 1)
    assert(has(buf, '[cancelled]\n\nPrompt: q1\n\nAgent:\nhello\n\n[completed]'), text(buf))
    keys('<S-CR>')
    assert(warned(buf, 'Nothing to send'), text(buf))
    finish()
end)

test('commands during a turn', function()
    local acp = load('acp-basic')
    local agent_mode = 'https://agentclientprotocol.com/protocol/session-modes#agent'
    local plan_mode = 'https://agentclientprotocol.com/protocol/session-modes#plan'
    local function options(model)
        return {
            {
                id = 'model',
                name = 'Model',
                category = 'model',
                type = 'select',
                currentValue = model,
                options = { { value = 'm1', name = 'One' }, { value = 'm2', name = 'Two' } },
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
            configOptions = options('m1'),
            modes = {
                currentModeId = agent_mode,
                availableModes = {
                    { id = agent_mode, name = 'Agent' },
                    { id = plan_mode, name = 'Plan' },
                },
            },
        }, 'new'),
    })
    -- Settings change on the agent during the turn.
    local hello = prompt('hello', 300)
    for k, step in ipairs({
        expect('session/set_config_option', { sessionId = 's1', configId = 'model', value = 'm2' }),
        respond({ configOptions = options('m2') }),
        expect('session/set_mode', { sessionId = 's1', modeId = plan_mode }),
        respond(vim.empty_dict()),
    }) do
        table.insert(hello, 2 + k, step)
    end
    vim.list_extend(s, hello)
    vim.list_extend(s, prompt('/permissions allow-all'))
    vim.list_extend(s, prompt('q1'))
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

    -- Settings typed during a turn change at once, also through <S-Tab>;
    -- prompts and agent commands are queued.
    type_draft(buf, '/model m2')
    enter(buf)
    await(function()
        return state(buf).model == 'Two'
    end, 'model during the turn')
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    keys('<S-Tab>')
    for _, line in ipairs({ '/permissions allow-all', 'q1' }) do
        type_draft(buf, line)
        enter(buf)
    end
    assert(virtual(buf) == 'Queued: /permissions allow-all\nQueued: q1', virtual(buf))
    await(function()
        return state(buf).mode == 'Plan' and status(buf, 'running')
    end, 'settings during the turn')
    assert(
        has(
            buf,
            'Prompt: /model m2\n\n[Setting: model = Two]\n\n'
                .. 'Prompt: /mode plan\n\n[Setting: mode = Plan]'
        ),
        text(buf)
    )
    -- Commands that replace the session wait for the turn.
    type_draft(buf, '/new')
    enter(buf)
    assert(draft(buf) == '/new', draft(buf))
    assert(warned(buf, 'A turn is still active'), text(buf))
    type_draft(buf, '')
    turn(buf, 3)
    assert(
        has(
            buf,
            'Prompt: /permissions allow-all\n\nAgent:\nhello\n\n[completed]\n\n'
                .. 'Prompt: q1\n\nAgent:\nhello\n\n[completed]'
        ),
        text(buf)
    )
    assert(state(buf).model == 'Two' and state(buf).mode == 'Plan', vim.inspect(state(buf)))
    assert(state(buf).queued == nil and virtual(buf) == '', virtual(buf))
    -- A refused setting is reported.
    assert(boomer.model('One'))
    await(function()
        return has(buf, 'Error: nope')
    end, 'refused setting')
    assert(state(buf).model == 'Two')
    finish()

    -- Native Codex compaction is a turn of its own: it waits for the
    -- running one.
    local base = load('codex-basic')
    s = steps(base, 1, 7)
    local t = steps(base, 8, 11)
    table.insert(t, 4, { op = 'delay', ms = 300 })
    vim.list_extend(s, t)
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
    buf = open({ version = 1, profile = 'codex-v2', steps = s })
    send(buf, 'hello')
    type_draft(buf, '/compact')
    enter(buf)
    assert(draft(buf) == '/compact' and warned(buf, 'A turn is still active'), text(buf))
    turn(buf)
    enter(buf)
    await(function()
        return has(buf, 'Prompt: /compact\n\n[compacted]') and status(buf, 'ready')
    end, 'compacted')
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
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 7) }
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
        -- Servers that do not list decisions get the standard ones.
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
        }),
        response('a1', { decision = 'acceptForSession' }),
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
    })
    local asked = 0
    local function approve(items, opts, cb)
        asked = asked + 1
        local labels = vim.tbl_map(opts.format_item, items)
        if #labels == 2 then
            return pick('Grant for this turn')(items, opts, cb)
        end
        assert(#labels == 4 and labels[1] == 'Deny', vim.inspect(labels))
        pick('Allow for this session')(items, opts, cb)
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
    assert(has(buf, 'Prompt: /usage\n\nUsage |'), text(buf))
    -- Commands that need no agent traffic.
    assert(boomer.resume('s1'), 'resume the current session')
    assert(has(buf, 'Prompt: /resume s1\n\n[Session: Named (current)]'), text(buf))
    assert(not boomer.compact('focus'))
    assert(warned(buf, 'This agent takes no compaction instructions'), text(buf))
    boomer.permissions('bogus')
    assert(warned(buf, 'Unknown permissions: bogus'), text(buf))
    vim.ui.select = pick('codex (codex) [current]')
    assert(boomer.agent())
    pause(20)
    assert(state(buf).agent == 'codex' and api.nvim_buf_is_valid(buf), 'same agent replaced')
    assert(has(buf, 'Prompt: /agent codex\n\n[Agent: codex (current)]'), text(buf))
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

    -- A function winbar that fails shows nothing.
    require('boomer.config').options.winbar = function()
        error('bad winbar')
    end
    assert(winbar(buf) == '', winbar(buf))
    finish()

    -- Without the model list the chat works; the default model is skipped.
    scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 3) }
    vim.list_extend(scenario.steps, { expect('model/list', { limit = 100 }), reject('offline') })
    vim.list_extend(scenario.steps, steps(base, 6, 7))
    buf = open(scenario, nil, { agents = { codex = { model = 'm2' } } })
    ready(buf)
    assert(has(buf, 'Error: model list: offline'), text(buf))
    assert(has(buf, 'Error: default model: m2 is not offered by this agent'), text(buf))
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
        {
            op = 'send_notification',
            messages = {
                update({
                    sessionUpdate = 'usage_update',
                    used = 300,
                    size = 1000,
                    cost = { amount = 0.5, currency = 'USD' },
                }),
            },
        },
        respond({ stopReason = 'end_turn' }),
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
    assert(has(buf, 'Context: 300 of 1.0k tokens (30%)'), text(buf))
    -- Agent commands run from Ex are echoed as the user's message.
    vim.cmd('Boomer /plan go')
    await(function()
        return has(buf, '[max_tokens]') and status(buf, 'ready')
    end, 'agent command')
    assert(has(buf, 'Prompt: /plan go'), text(buf))

    assert(not boomer.compact())
    assert(warned(buf, 'This agent cannot compact the conversation'), text(buf))
    boomer.resume()
    await(function()
        return warned(buf, 'this agent cannot list sessions')
    end, 'list unsupported')
    boomer.resume('s5')
    await(function()
        return status(api.nvim_get_current_buf(), 'no session')
    end, 'load unsupported')
    assert(has(api.nvim_get_current_buf(), 'Error: this agent cannot load sessions'))
    finish()
end)

-- Byte ranges of `group` highlights on `row`, as "start-end" strings.
local function ranges(buf, row, group)
    local out = {}
    for _, m in
        ipairs(api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, {
            details = true,
        }))
    do
        if m[4].hl_group == group then
            out[#out + 1] = m[3] .. '-' .. m[4].end_col
        end
    end
    return table.concat(out, ' ')
end

test('diffs', function()
    -- Rendering: headers with paths relative to the cwd, a cut-off, and
    -- diff-mode highlights with the changed part of paired lines.
    local view = new_view()
    local buf = view.buf
    view.cwd, view.diff_lines = cwd, 8
    view:write('[Tool: edit]')
    view:diff({
        {
            from = vim.fs.joinpath(cwd, 'a.lua'),
            to = vim.fs.joinpath(cwd, 'a.lua'),
            text = '@@ -1,4 +1,4 @@\n a\n-local x = 1\n+local x = 2\n-é b\n+é c\n-gone\n',
        },
        { to = '/elsewhere/n.md', text = '@@ -0,0 +1,2 @@\n+````\n+z\n' },
    })
    assert(
        has(
            buf,
            '[Tool: edit]\n\n```diff\n--- a.lua\n+++ a.lua\n@@ -1,4 +1,4 @@\n a\n'
                .. '-local x = 1\n+local x = 2\n-é b\n+é c\n... 6 more lines\n```\n'
        ),
        text(buf)
    )
    assert(marks(buf, row_of(buf, '```diff'), 'hl_group', 'BoomerSystem'))
    assert(marks(buf, row_of(buf, '--- a.lua'), 'hl_group', 'BoomerSystem'))
    assert(marks(buf, row_of(buf, '@@ -1,4'), 'hl_group', 'BoomerDiffHunk'))
    assert(marks(buf, row_of(buf, '6 more lines'), 'hl_group', 'BoomerSystem'))
    local del, add = row_of(buf, '-local x'), row_of(buf, '+local x')
    assert(marks(buf, del, 'line_hl_group', 'BoomerDiffDelete'))
    assert(marks(buf, add, 'line_hl_group', 'BoomerDiffAdd'))
    assert(not marks(buf, row_of(buf, '@@ -1,4') + 1, 'line_hl_group', 'BoomerDiffAdd'))
    assert(ranges(buf, del, 'BoomerDiffText') == '11-12', ranges(buf, del, 'BoomerDiffText'))
    assert(ranges(buf, add, 'BoomerDiffText') == '11-12')
    -- Multibyte characters are not split.
    assert(ranges(buf, row_of(buf, '-é b'), 'BoomerDiffText') == '4-5')
    -- Without a cut-off: unpaired lines get no changed part; the fence
    -- outgrows backticks in the diff; paths elsewhere stay absolute; lines
    -- without a final newline are paired.
    view.diff_lines = nil
    view:diff({
        { to = '/elsewhere/n.md', text = '@@ -0,0 +1,2 @@\n+````\n+z\n' },
        { from = vim.fs.joinpath(cwd, 'old'), text = '@@ -1 +0,0 @@\n-y\n' },
        { from = vim.fs.joinpath(cwd, 'b'), to = '/x/c', text = '' },
        {
            from = vim.fs.joinpath(cwd, 'v'),
            to = vim.fs.joinpath(cwd, 'v'),
            text = '@@ -1 +1 @@\n-old v\n\\ No newline at end of file\n+new v\n'
                .. '\\ No newline at end of file\n',
        },
    })
    assert(
        has(
            buf,
            '\n\n`````diff\n--- /dev/null\n+++ /elsewhere/n.md\n@@ -0,0 +1,2 @@\n+````\n+z\n'
                .. '--- old\n+++ /dev/null\n@@ -1 +0,0 @@\n-y\n--- b\n+++ /x/c\n--- v\n+++ v\n'
                .. '@@ -1 +1 @@\n-old v\n\\ No newline at end of file\n+new v\n'
                .. '\\ No newline at end of file\n`````\n'
        ),
        text(buf)
    )
    assert(ranges(buf, row_of(buf, '+z'), 'BoomerDiffText') == '')
    assert(ranges(buf, row_of(buf, '-old v'), 'BoomerDiffText') == '1-4')
    assert(ranges(buf, row_of(buf, '+new v'), 'BoomerDiffText') == '1-4')
    assert(api.nvim_get_hl(0, { name = 'BoomerDiffText' }).link == 'DiffText')
    api.nvim_buf_delete(buf, { force = true })

    -- Codex: a diff is shown once per file change item, after its tool line
    -- (also without a permission request); a request that comes first shows
    -- the latest streamed patch before it.
    local scenario = load('codex-fileChange')
    local function item(method, it)
        return { method = method, params = { threadId = 's1', item = it } }
    end
    local changes = {
        {
            path = vim.fs.joinpath(cwd, 'a.lua'),
            kind = { type = 'update' },
            diff = '@@ -1 +1 @@\n-x\n+y\n',
        },
        { path = vim.fs.joinpath(cwd, 'new.txt'), kind = { type = 'add' }, diff = 'hi\n' },
        { path = vim.fs.joinpath(cwd, 'gone.txt'), kind = { type = 'delete' }, diff = 'bye\n' },
        {
            path = vim.fs.joinpath(cwd, 'm.lua'),
            kind = { type = 'update', move_path = vim.fs.joinpath(cwd, 'n.lua') },
            diff = '\n\nMoved to: ' .. vim.fs.joinpath(cwd, 'n.lua'),
        },
    }
    local started = item('item/started', { type = 'fileChange', id = 'tool1', changes = changes })
    local completed = vim.deepcopy(started)
    completed.method, completed.params.item.status = 'item/completed', 'completed'
    local patch = function(diff)
        return {
            method = 'item/fileChange/patchUpdated',
            params = {
                threadId = 's1',
                turnId = 't1',
                itemId = 'tool2',
                changes = { { path = 'p.lua', kind = { type = 'update' }, diff = diff } },
            },
        }
    end
    table.insert(scenario.steps, 10, {
        op = 'send_notification',
        messages = { started, patch('@@ -1 +1 @@\n-p\n+partial\n'), patch('@@ -1 +1 @@\n-p\n+q\n') },
    })
    local second = vim.deepcopy(scenario.steps[11])
    second.message.id, second.message.params.itemId = 'permission2', 'tool2'
    local answer = vim.deepcopy(scenario.steps[12])
    answer.message.id = 'permission2'
    table.insert(scenario.steps, 13, second)
    table.insert(scenario.steps, 14, answer)
    table.insert(scenario.steps, 15, { op = 'send_notification', message = completed })
    vim.ui.select = pick('Allow once')
    buf = open(scenario)
    send(buf)
    turn(buf)
    local edit = 'edit '
        .. table.concat(
            vim.tbl_map(function(c)
                return c.path
            end, changes),
            ', '
        )
    assert(
        has(
            buf,
            '[Tool: '
                .. edit
                .. ']\n\n```diff\n--- a.lua\n+++ a.lua\n@@ -1 +1 @@\n-x\n+y\n'
                .. '--- /dev/null\n+++ new.txt\n@@ -0,0 +1 @@\n+hi\n'
                .. '--- gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\n'
                .. '--- m.lua\n+++ n.lua\n```\n\nPermission: Apply file changes\n'
        ),
        text(buf)
    )
    assert(count(buf, '```diff') == 2 and count(buf, 'Permission: Apply') == 2, text(buf))
    assert(has(buf, '```diff\n--- p.lua\n+++ p.lua\n@@ -1 +1 @@\n-p\n+q\n```\n\nPermission:'))
    assert(not has(buf, 'partial'), text(buf))
    finish()

    -- ACP: diffs of auto-approved tool calls are shown once, also when the
    -- tool call failed; one first sent with a permission request is shown
    -- before it. Cut off at diff_lines.
    scenario = load('acp-permission-accept')
    local function update(u)
        return { method = 'session/update', params = { sessionId = 's1', update = u } }
    end
    local content = {
        { type = 'content', content = { type = 'text', text = 'ok' } },
        { type = 'diff', path = vim.fs.joinpath(cwd, 'a.lua'), oldText = 'a\n', newText = 'b\n' },
    }
    table.insert(scenario.steps, 6, {
        op = 'send_notification',
        messages = {
            update({ sessionUpdate = 'tool_call', toolCallId = 't0', title = 'Edit a.lua' }),
            update({ sessionUpdate = 'tool_call_update', toolCallId = 't0', content = content }),
            update({ sessionUpdate = 'tool_call_update', toolCallId = 't0', content = content }),
            update({
                sessionUpdate = 'tool_call',
                toolCallId = 't9',
                title = 'Edit same',
                content = { { type = 'diff', path = '/x', oldText = 's\n', newText = 's\n' } },
            }),
            update({
                sessionUpdate = 'tool_call_update',
                toolCallId = 't9',
                status = 'failed',
                content = { { type = 'diff', path = '/f', oldText = 'f\n', newText = 'g\n' } },
            }),
        },
    })
    scenario.steps[7].message.params.toolCall.content = {
        {
            type = 'diff',
            path = vim.fs.joinpath(cwd, 'new.lua'),
            oldText = vim.NIL,
            newText = 'n\n',
        },
    }
    vim.ui.select = pick('Allow once')
    buf = open(scenario, 'copilot', { diff_lines = 4 })
    send(buf)
    turn(buf)
    assert(
        has(
            buf,
            '[Tool: Edit a.lua]\n\n```diff\n--- a.lua\n+++ a.lua\n@@ -1 +1 @@\n-a\n... 1 more line\n```\n'
        ),
        text(buf)
    )
    assert(
        has(
            buf,
            '```diff\n--- /dev/null\n+++ new.lua\n@@ -0,0 +1 @@\n+n\n```\n\nPermission: test\n'
        ),
        text(buf)
    )
    assert(has(buf, '[Tool: Edit same | failed]\n\n```diff\n--- /f\n'), text(buf))
    assert(count(buf, '```diff') == 3, 'unchanged file or repeated diff shown: ' .. text(buf))
    finish()

    -- Copilot CLI: a permission request has only rawInput.diff, a git-style
    -- diff; the completed tool call then sends every file of the tool call
    -- as content, where files already shown are skipped.
    scenario = load('acp-permission-accept')
    local call = scenario.steps[6].message.params.toolCall
    call.title = 'Create file'
    call.rawInput = {
        fileName = vim.fs.joinpath(cwd, 'b.txt'),
        diff = table.concat({
            '',
            'diff --git a/tmp/b.txt b/tmp/b.txt',
            'create file mode 100644',
            'index 0000000..0000000',
            '--- a/dev/null',
            '+++ b/tmp/b.txt',
            'copilot:whole-file-v1',
            '@@ -1,0 +1,1 @@',
            '+hello',
            '',
            '',
        }, '\n'),
    }
    table.insert(scenario.steps, 8, {
        op = 'send_notification',
        message = update({
            sessionUpdate = 'tool_call_update',
            toolCallId = 'tool1',
            status = 'completed',
            content = {
                {
                    type = 'diff',
                    path = vim.fs.joinpath(cwd, 'b.txt'),
                    oldText = '',
                    newText = 'hello\n',
                },
                {
                    type = 'diff',
                    path = vim.fs.joinpath(cwd, 'gone.txt'),
                    oldText = 'old\n',
                    newText = '',
                },
            },
        }),
    })
    vim.ui.select = pick('Allow once')
    buf = open(scenario, 'copilot')
    send(buf)
    turn(buf)
    assert(
        has(
            buf,
            '```diff\n--- /dev/null\n+++ b.txt\n@@ -1,0 +1,1 @@\n+hello\n```\n\nPermission: Create file\n'
        ),
        text(buf)
    )
    assert(has(buf, '```diff\n--- gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n```'), text(buf))
    assert(count(buf, '```diff') == 2, 'repeated diff shown: ' .. text(buf))
    finish()
end)

test('completion', function()
    -- Codex models are listed at startup.
    local base = load('codex-basic')
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 7) }
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
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer /effort ', 'cmdline'), { 'high' }))
    -- Prompt text completes nothing.
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer mod', 'cmdline'), {}))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer why /mod', 'cmdline'), {}))
    type_draft(buf, '')
    -- Sessions are picked, not completed.
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer /resume ', 'cmdline'), {}))
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
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer /model ', 'cmdline'), { 'a', 'b' }))
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
    local scenario = { version = 1, profile = 'codex-v2', steps = steps(base, 1, 11, base, 6, 7) }
    scenario.steps[8].message.params.input[1].text = 'sent x'
    local buf, saved
    buf = open(scenario, nil, {
        commands = {
            go = {
                run = function(args, ctx)
                    assert(ctx.buf == buf and ctx.status.agent == 'codex')
                    assert(ctx.send('sent ' .. args))
                    saved = ctx
                end,
            },
            bad = {
                run = function()
                    error('oops', 0)
                end,
            },
            empty = { prompt = ' ' },
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
    local notified = #notices
    assert(not boomer.run('/bad') and warned(buf, '/bad: oops'), text(buf))
    assert(not boomer.run('/empty') and warned(buf, '/empty produced an empty prompt'))
    assert(not boomer.run('/nope') and warned(buf, 'Unknown command /nope'))
    assert(#notices == notified, 'notified while the chat is shown: ' .. notices[#notices])
    -- A hidden chat is notified too.
    vim.cmd('close')
    assert(not boomer.run('/bad') and count(buf, 'Warning: /bad: oops') == 2, text(buf))
    assert(notices[#notices] == '/bad: oops', notices[#notices])
    boomer.open()
    local files = vim.fn.getcompletion('Boomer /files ', 'cmdline')
    assert(vim.deep_equal(files, { 'codex.lua', 'b.lua' }), vim.inspect(files))
    assert(vim.deep_equal(vim.fn.getcompletion('Boomer /fixed t', 'cmdline'), { 'two' }))

    assert(boomer.run('/go x'), text(buf))
    turn(buf)
    assert(has(buf, 'Prompt: /go x\n\nPrompt: sent x'), text(buf))
    -- The omnifunc only completes on the prompt line.
    api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    api.nvim_win_set_cursor(0, { 1, 0 })
    assert(boomer.omnifunc(1, '') == -3)
    -- A command's context outlives its session but no longer acts.
    assert(boomer.new())
    local fresh = api.nvim_get_current_buf()
    assert(fresh ~= buf)
    ready(fresh)
    assert(not saved.send('late'))
    saved.write('LATE')
    pause(30)
    assert(not has(fresh, 'LATE'), text(fresh))
    finish()
end)

test(':Boomer prompts and ranges', function()
    local base = load('codex-basic')
    local scenario = {
        version = 1,
        profile = 'codex-v2',
        steps = steps(base, 1, 11, base, 8, 11, base, 8, 11, base, 8, 11),
    }
    scenario.steps[12].message.params.input[1].text = '/x'
    scenario.steps[20].message.params.input[1].text = 'tab'
    scenario.steps[16].message.params.input[1].text = 'why\n\nboomer-range.lua:2-3\n'
        .. '````lua\nlocal function f()\n  return "``` x"\n````'
    play(scenario)
    -- An unsaved buffer: its lines are sent as they are in Neovim.
    vim.cmd.edit(vim.fn.fnameescape(cwd .. '/boomer-range.lua'))
    local code, file = api.nvim_get_current_win(), api.nvim_get_current_buf()
    api.nvim_buf_set_lines(
        file,
        0,
        -1,
        false,
        { 'local a = 1', 'local function f()', '  return "``` x"', 'end' }
    )

    -- Without a chat, a prompt starts one and is sent; focus stays.
    assert(boomer.run('hello'))
    local buf = boomer.status().buf
    assert(api.nvim_get_current_win() == code and #vim.fn.win_findbuf(buf) == 1)
    -- A queued range returns to the draft with its code.
    vim.cmd('1Boomer early')
    vim.cmd('Boomer /cancel')
    local back = 'hello\n\nearly\n\nboomer-range.lua:1\n```lua\nlocal a = 1\n```'
    assert(draft(buf) == back, draft(buf))
    type_draft(buf, '')
    vim.cmd('Boomer hello')
    turn(buf)
    assert(has(buf, 'Prompt: hello'), text(buf))
    vim.cmd('Boomer //x')
    turn(buf, 2)
    assert(has(buf, 'Prompt: //x') and api.nvim_get_current_win() == code, text(buf))

    -- A range goes with the prompt; the transcript names it.
    vim.cmd('2,3Boomer why')
    assert(api.nvim_get_current_win() == code)
    turn(buf, 3)
    assert(has(buf, 'Prompt: why [boomer-range.lua:2-3]\n'), text(buf))
    assert(not has(buf, 'local function f'), 'the transcript shows the code')

    -- A line that cannot run only warns.
    type_draft(buf, 'keep')
    vim.cmd('Boomer /new foo')
    vim.cmd('2Boomer /model')
    assert(warned(buf, '/new takes no arguments'), text(buf))
    assert(warned(buf, 'A range takes a prompt, not a command'), text(buf))
    assert(draft(buf) == 'keep' and api.nvim_get_current_win() == code, draft(buf))

    -- A range without text goes into the draft, and the chat is focused.
    vim.cmd('1Boomer')
    assert(api.nvim_get_current_buf() == buf)
    assert(draft(buf) == 'keep\n\nboomer-range.lua:1\n```lua\nlocal a = 1\n```', draft(buf))
    vim.cmd('1Boomer x')
    assert(warned(buf, 'Select lines in another buffer'), text(buf))
    type_draft(buf, '')

    -- A prompt from another tab page shows the chat there too.
    vim.cmd('tabnew')
    local other = api.nvim_get_current_win()
    vim.cmd('Boomer tab')
    assert(api.nvim_get_current_win() == other)
    assert(#vim.fn.win_findbuf(buf) == 2 and vim.fn.tabpagebuflist()[2] == buf)
    turn(buf, 4)
    vim.cmd('tabclose')

    -- A command's picker opens from another window and leaves it current.
    api.nvim_set_current_win(code)
    local offered
    vim.ui.select = function(items, _, cb)
        offered = vim.tbl_map(function(item)
            return item.value
        end, items)
        cb(items[2], 2)
    end
    vim.cmd('Boomer /model')
    await(function()
        return state(buf).model == 'm2'
    end, 'model picked')
    assert(vim.deep_equal(offered, { 'm1', 'm2' }), vim.inspect(offered))
    assert(api.nvim_get_current_win() == code and api.nvim_get_mode().mode == 'n')
    finish()
    vim.cmd('silent! bwipeout! ' .. file)
end)

test('VimLeavePre does not wait', function()
    local scenario = load('codex-basic')
    for i = #scenario.steps, 8, -1 do
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
