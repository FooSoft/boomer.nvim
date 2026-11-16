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
    require('boomer').run(o.args)
end, {
    nargs = '*',
    desc = 'Boomer chat: open, or run a subcommand',
    complete = function(...)
        return require('boomer').complete(...)
    end,
})
