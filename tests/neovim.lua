-- Real Neovim LSP client smoke test. No user configuration is loaded.
local exe = assert(vim.env.DOTLS_BIN)
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, '/private/tmp/dotls-editor-smoke.dot')
vim.bo[buf].filetype = 'dot'
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'digraph G { a -> }'})
local client_id = assert(vim.lsp.start({name='dot-ls', cmd={exe,'lsp'}, root_dir=vim.fn.getcwd()}, {bufnr=buf}))
local function wait_for(predicate, label)
  assert(vim.wait(10000, predicate, 10), label)
end
wait_for(function() return #vim.diagnostic.get(buf) > 0 end, 'missing syntax diagnostic')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'digraph G { a -> b }'})
wait_for(function() return #vim.diagnostic.get(buf) == 0 end, 'diagnostics did not clear after repair')
local client = assert(vim.lsp.get_client_by_id(client_id))
assert(client.server_capabilities.textDocumentSync.change == 1)
assert(client.server_capabilities.completionProvider)
local reply = assert(client:request_sync('textDocument/completion', {textDocument={uri=vim.uri_from_bufnr(buf)}, position={line=0,character=0}}, 5000, buf))
assert(reply.result and #reply.result.items == 3, 'missing keyword completions')
assert(client.server_capabilities.referencesProvider)
local refs = assert(client:request_sync('textDocument/references', {textDocument={uri=vim.uri_from_bufnr(buf)}, position={line=0,character=12}, context={includeDeclaration=true}}, 5000, buf))
assert(refs.result and #refs.result == 1, 'missing node reference')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'digraph { a [label=<<B>x</I>>]; }'})
wait_for(function()
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.message:find('HTML label:', 1, true) then return true end
  end
  return false
end, 'missing delayed HTML diagnostic')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'digraph { a [label=<<B>x</B>>]; }'})
wait_for(function() return #vim.diagnostic.get(buf) == 0 end, 'HTML diagnostic did not clear')
client:stop()
wait_for(function() return client:is_stopped() end, 'server did not stop')
print('Neovim: attachment, diagnostics, repair, completion, references, HTML repair, and shutdown passed')
vim.cmd('qa!')
