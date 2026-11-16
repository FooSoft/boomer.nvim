-- :checkhealth boomer: the Neovim version, the Markdown parser used to
-- render the chat, and whether each agent's executable is installed.
local M = {}

-- First line of `cmd --version`, or nil (with a timeout, as agents may hang).
-- The result is nil if the process outlives its kill (on Windows, an agent
-- behind a .cmd shim keeps the pipes open).
local function version(cmd)
    local ok, obj = pcall(function()
        return vim.system({ cmd, '--version' }, { text = true }):wait(3000)
    end)
    if ok and obj and obj.code == 0 then
        return vim.trim((obj.stdout or ''):match('[^\n]*'))
    end
end

function M.check()
    local health = vim.health
    health.start('boomer')
    if vim.fn.has('nvim-0.12') == 1 then
        health.ok('Neovim ' .. tostring(vim.version()))
    else
        health.error('Neovim 0.12 or newer is required')
    end
    if pcall(vim.treesitter.language.inspect, 'markdown') then
        health.ok('Treesitter markdown parser found')
    else
        health.warn('No treesitter markdown parser; the chat is shown without highlighting')
    end

    local config = require('boomer.config')
    health.start('boomer agents')
    for _, name in ipairs(config.agent_names()) do
        local p = config.options.agents[name]
        local label = ('%s (%s: %s)'):format(name, p.protocol, p.command)
        local default = name == config.options.agent and ' [default]' or ''
        if vim.fn.executable(p.command) == 0 then
            -- Only the default agent is required.
            local msg = label .. default .. ': executable not found'
            if default ~= '' then
                health.error(msg, { 'Install it or set `agents.' .. name .. '.command`' })
            else
                health.info(msg)
            end
        else
            local v = version(p.command)
            health.ok(label .. default .. (v and (': ' .. v) or ''))
        end
    end
end

return M
