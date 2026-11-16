-- Scenario peer for tests: plays tests/scenarios/*.json over stdio. Independent
-- of the plugin's RPC code so a framing bug is not mirrored here.
local uv, json = vim.uv, vim.json
local f = assert(io.open((assert(arg[1], 'scenario path required'))))
local scenario = json.decode(f:read('*a'))
f:close()
local acp = scenario.profile == 'acp-v1'
if scenario.ignore_sigterm then
    -- Nvim's own SIGTERM handler would exit; override it with SIG_IGN.
    local ffi = require('ffi')
    ffi.cdef('typedef void (*sighandler_t)(int); sighandler_t signal(int, sighandler_t);')
    ffi.C.signal(15, ffi.cast('sighandler_t', 1))
end
local input, output = uv.new_pipe(false), uv.new_pipe(false)
input:open(0)
output:open(1)
local vars, inbox, index, waiting, finished, alive = {}, {}, 1, false, false, true

local function timer(ms, fn)
    local t = uv.new_timer()
    t:start(ms, 0, function()
        t:close()
        fn()
    end)
    return t
end

-- stderr ends up in the plugin's exit error, so failures show in the transcript.
local function die(message)
    io.stderr:write('scenario step ', index, ': ', tostring(message), '\n')
    os.exit(2)
end

local function substitute(v)
    if type(v) ~= 'table' then
        return v
    elseif v.ref then
        assert(vars[v.ref] ~= nil, 'unknown capture ' .. v.ref)
        return vars[v.ref]
    end
    local t = setmetatable({}, getmetatable(v))
    for k, x in pairs(v) do
        t[k] = substitute(x)
    end
    return t
end

-- Exact match except captures. Missing differs from null, {} differs from [].
local function match(expected, actual)
    if type(expected) == 'table' and expected.capture then
        vars[expected.capture] = actual
        return actual ~= nil
    elseif type(expected) ~= 'table' or type(actual) ~= 'table' then
        return expected == actual
    elseif next(expected) == nil and next(actual) == nil then
        return getmetatable(expected) == getmetatable(actual)
    end
    for k, v in pairs(expected) do
        if not match(v, actual[k]) then
            return false
        end
    end
    for k in pairs(actual) do
        if expected[k] == nil then
            return false
        end
    end
    return true
end

local function encode(msg)
    msg = substitute(msg)
    msg.jsonrpc = acp and '2.0' or nil
    return json.encode(msg) .. '\n'
end

local step_timer
local function advance()
    if waiting or finished then
        return
    end
    local step = scenario.steps[index]
    if step_timer then
        step_timer:stop()
        step_timer:close()
        step_timer = nil
    end
    if not step then
        finished = true
        return -- stay alive until the client closes stdin
    end
    step_timer = timer(scenario.step_timeout_ms or 2000, function()
        die('step deadline exceeded')
    end)
    if step.op:match('^expect_') or step.op == 'parallel' then
        step.remaining = step.remaining or (step.messages or { step.message })
        while #inbox > 0 and #step.remaining > 0 do
            local msg, found = table.remove(inbox, 1), nil
            for j, e in ipairs(step.remaining) do
                local snapshot = {}
                for k, v in pairs(vars) do
                    snapshot[k] = v
                end
                if match(substitute(e), msg) then
                    found = j
                    break
                end
                vars = snapshot
            end
            if not found then
                die('unexpected message ' .. json.encode(msg))
            end
            table.remove(step.remaining, found)
        end
        if #step.remaining > 0 then
            return
        end
    elseif step.op:match('^send_') then
        local data = {}
        for _, m in ipairs(step.messages or { step.message }) do
            data[#data + 1] = encode(m)
        end
        data = table.concat(data)
        local pos = 1
        for _, size in ipairs(step.fragments or {}) do
            output:write(data:sub(pos, pos + size - 1))
            pos = pos + size
        end
        output:write(data:sub(pos))
    elseif step.op == 'write_raw' then
        output:write(step.data)
    elseif step.op == 'stderr' then
        io.stderr:write(step.data)
    elseif step.op == 'delay' then
        waiting = true
        timer(step.ms, function()
            waiting = false
            advance()
        end)
    elseif step.op == 'close_stdout' then
        output:close()
    elseif step.op == 'exit' then
        waiting = true
        timer(step.ms or 10, function()
            os.exit(step.code or 0)
        end)
    else
        die('unknown operation ' .. tostring(step.op))
    end
    index = index + 1
    advance()
end

local buffer = ''
input:read_start(function(err, data)
    if err then
        die(err)
    elseif not data then
        if not scenario.ignore_eof and (#inbox > 0 or not finished) then
            die('EOF before scenario completed')
        end
        input:close()
        alive = scenario.ignore_eof
        return
    end
    buffer = buffer .. data
    while true do
        local nl = buffer:find('\n', 1, true)
        if not nl then
            break
        end
        local ok, msg = pcall(json.decode, buffer:sub(1, nl - 1))
        buffer = buffer:sub(nl + 1)
        if not ok then
            die(msg)
        elseif acp and msg.jsonrpc ~= '2.0' then
            die('missing jsonrpc')
        elseif not acp and msg.jsonrpc ~= nil then
            die('unexpected jsonrpc')
        end
        msg.jsonrpc = nil
        inbox[#inbox + 1] = msg
    end
    if finished and #inbox > 0 then
        die('unexpected traffic after final step: ' .. json.encode(inbox[1]))
    end
    local ok, e = pcall(advance)
    if not ok then
        die(e)
    end
end)
timer(scenario.timeout_ms or 10000, function()
    die('scenario deadline exceeded')
end)
advance()
while alive do
    vim.wait(10)
end
