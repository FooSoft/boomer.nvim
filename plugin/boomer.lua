-- Entry point: defines :Boomer only. Everything else loads on first use.
if vim.g.loaded_boomer then
    return
end
vim.g.loaded_boomer = true

if vim.fn.has('nvim-0.12') == 0 then
    vim.notify('Boomer requires Neovim 0.12 or newer', vim.log.levels.ERROR)
    return
end

vim.api.nvim_create_user_command('Boomer', function(o)
    local range = o.range > 0
        and { buf = vim.api.nvim_get_current_buf(), line1 = o.line1, line2 = o.line2 }
    require('boomer').run(o.args, range or nil)
end, {
    nargs = '*',
    range = true,
    desc = 'Boomer chat: open, send a prompt or run a /command',
    complete = function(...)
        return require('boomer').complete(...)
    end,
})
