-- nvim --clean --headless -l tests/real.lua codex|copilot [--allow-inference]
--
-- Opt-in check against an installed, already authenticated agent (a built-in
-- profile). Without --allow-inference it only initializes and shuts down.
local backend = arg[1]
if backend ~= 'codex' and backend ~= 'copilot' then
    io.stdout:write('SKIP real suite: pass codex or copilot (uses existing auth/config)\n')
    os.exit(0)
end
local allow = arg[2] == '--allow-inference'
assert(#arg == 1 or allow and #arg == 2, 'unknown real-suite argument')
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(arg[0], ':p:h:h'))
local config = require('boomer.config')

local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, 'p')
local reply, failure, done = {}, nil, false
local client
local function finish(err)
    if not done then
        done, failure = true, err
    end
end
local on = {
    text = function(role, text)
        if role == 'agent' then
            reply[#reply + 1] = text
        end
    end,
    tool = function() end,
    diff = function() end,
    settled = function() end,
    error = function(msg)
        io.stderr:write('error: ', msg, '\n')
    end,
    permission = function(req)
        req.reply(req.deny)
    end,
    exit = function(msg)
        finish(msg)
    end,
    status = function() end,
    commands = function() end,
}
vim.fn.chdir(workspace)
local profile = assert(config.resolve(backend))
local err
client, err = require(config.protocols[profile.protocol]).start(profile, on, function(e)
    if e or not allow then
        return finish(e and e.message)
    end
    client:new_session(profile.cwd, function(se)
        if se then
            return finish(se.message)
        end
        client:prompt('Reply with one short greeting. Do not use tools or modify files.', function(pe, r)
            io.stdout:write('result: ', tostring(r), '\nreply: ', table.concat(reply), '\n')
            finish(pe and pe.message)
        end)
    end)
end)
if not client then
    finish(err)
elseif not vim.wait(allow and 120000 or 40000, function()
    return done
end, 50) then
    finish('real compatibility deadline')
end
if client then
    client:close()
    -- Windows cannot delete a directory that a running process works in.
    vim.wait(5000, function()
        return client.rpc.exit ~= nil
    end, 50)
end
vim.fn.chdir(vim.fn.fnamemodify(workspace, ':h'))
vim.fn.delete(workspace, 'd')
if failure then
    io.stderr:write('not ok - real ', backend, ': ', failure, '\n')
    os.exit(1)
end
io.stdout:write('ok - real ', backend, ' ', allow and 'prompt' or 'initialize', '\n')
