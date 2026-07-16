local M = {}

local wincmd = 'split'

local function create_commands()
  vim.api.nvim_create_user_command('EditCodeBlock',
    function(opts) require('ecb').edit_code_block(opts) end,
    {
      nargs = '*',
      complete = function()
        return { "e", "edit", "split", "vsplit", "tabnew", "rightbelow", "leftabove" }
      end,
      desc = 'edit embedded code block in new window'
    })

  vim.api.nvim_create_user_command('EditCodeBlockOrg',
    function(opts) require('ecb').edit_code_block_org(opts) end,
    {
      nargs = '*',
      complete = function()
        return { "e", "edit", "split", "vsplit", "tabnew", "rightbelow", "leftabove" }
      end,
      desc = 'edit embedded org mode code block in new window'
    })

  vim.api.nvim_create_user_command('EditCodeBlockSelection',
    function(opts) require('ecb').edit_code_block_selection(opts) end,
    {
      nargs = '+',
      complete = function()
        return { "e", "edit", "split", "vsplit", "tabnew", "rightbelow", "leftabove" }
      end,
      desc = 'edit selected code in new window',
      range = true
    })
end


M.setup = function(opts)
  create_commands()

  if opts and opts.wincmd then
    wincmd = opts.wincmd
  end
end


local function safe_cursor(win, row, col)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_line_count(buf)

  row = math.max(1, math.min(row, lines))
  col = math.max(0, col)

  vim.api.nvim_win_set_cursor(win, { row, col })
end


local function create_edit_buffer(win_cmd, mdbufnr, row, col,
                                  srow, scol, erow, ecol, filetype)

  local original_win = vim.api.nvim_get_current_win()
  local original_buf = mdbufnr

  local lines

  if ecol ~= 0 then
    lines = vim.api.nvim_buf_get_lines(
      mdbufnr,
      srow,
      erow + 1,
      false
    )
  else
    lines = vim.api.nvim_buf_get_lines(
      mdbufnr,
      srow,
      erow,
      false
    )
  end


  local pre
  local post

  if #lines > 0 and erow - srow + 1 <= #lines then
    post = string.sub(lines[#lines], ecol + 1)
    lines[#lines] = string.sub(lines[#lines], 1, ecol)
  end

  if #lines > 0 and scol > 0 then
    pre = string.sub(lines[1], 1, scol)
    lines[1] = string.sub(lines[1], scol + 1)
  end


  local replace_current =
    win_cmd == "e" or win_cmd == "edit"


  if replace_current then
    vim.cmd("enew")
  else
    vim.cmd(win_cmd)
  end


  local win = vim.api.nvim_get_current_win()

  local bufnr = vim.api.nvim_create_buf(true, false)

  vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'hide')
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')
  vim.api.nvim_buf_set_option(bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(bufnr, 'filetype', filetype)

  vim.api.nvim_buf_set_name(
    bufnr,
    bufnr .. ":" .. vim.api.nvim_buf_get_name(mdbufnr)
  )

  vim.api.nvim_buf_set_lines(
    bufnr,
    0,
    -1,
    false,
    lines
  )

  vim.api.nvim_win_set_buf(win, bufnr)


  local crow = row - srow
  if crow < 1 then
    crow = 1
  end

  local ccol

  if crow > 1 then
    ccol = col
  else
    ccol = col - scol
  end

  safe_cursor(win, crow, ccol)


  vim.api.nvim_create_autocmd(
    'BufWriteCmd',
    {
      buffer = bufnr,

      callback = function()

        local edit_row, edit_col =
          unpack(vim.api.nvim_win_get_cursor(win))


        local nlines =
          vim.api.nvim_buf_get_lines(
            bufnr,
            0,
            -1,
            false
          )


        if #nlines > 0 and pre then
          nlines[1] = pre .. nlines[1]
        end

        if #nlines > 0 and post then
          nlines[#nlines] =
            nlines[#nlines] .. post
        end


        if ecol ~= 0 then
          vim.api.nvim_buf_set_lines(
            original_buf,
            srow,
            erow + 1,
            false,
            nlines
          )
        else
          vim.api.nvim_buf_set_lines(
            original_buf,
            srow,
            erow,
            false,
            nlines
          )
        end


        local target_row = edit_row + srow
        local target_col

        if edit_row > 1 then
          target_col = edit_col
        else
          target_col = edit_col + scol
        end


        if vim.api.nvim_win_is_valid(original_win) then

          vim.api.nvim_win_set_buf(
            original_win,
            original_buf
          )

          safe_cursor(
            original_win,
            target_row,
            target_col
          )

        end


        vim.api.nvim_buf_set_option(
          bufnr,
          'modified',
          false
        )


        vim.schedule(function()

          if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(
              bufnr,
              { force = true }
            )
          end

        end)

      end
    }
  )


  vim.api.nvim_create_autocmd(
    'BufUnload',
    {
      buffer = bufnr,

      callback = function()

        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_set_option(
            bufnr,
            'bufhidden',
            'wipe'
          )
        end

      end
    }
  )

end


M.edit_code_block = function(opts)

  local win_cmd = wincmd

  if opts and opts.args and opts.args ~= "" then
    win_cmd = opts.args
  end


  local parser = vim.treesitter.get_parser()

  if not parser then
    return
  end

  parser:parse()


  local node = vim.treesitter.get_node()

  -- Cursor inside code block
  if node then

    while node and
      node:type() ~= "fenced_code_block" and
      node:type() ~= "code_block" and
      node:type() ~= "block" do

      node = node:parent()

    end

  end


  -- Folded block fallback:
  -- look at the current line and parse around it
  if not node then

    local row, col =
      unpack(vim.api.nvim_win_get_cursor(0))

    local range = {
      row - 1,
      col,
      row - 1,
      col + 1
    }


    local lang =
      parser:language_for_range(range)


    if lang then

      for _, tree in ipairs(lang:trees()) do

        local root = tree:root()

        if vim.treesitter.node_contains(root, range) then

          node = root:named_descendant_for_range(
            row - 1,
            0,
            row - 1,
            -1
          )

          while node and
            node:type() ~= "fenced_code_block" and
            node:type() ~= "code_block" and
            node:type() ~= "block" do

            node = node:parent()

          end

        end

      end

    end

  end


  if not node then
    vim.notify(
      "No code block found",
      vim.log.levels.INFO
    )
    return
  end


  local srow, scol, erow, ecol =
    node:range(false)


  local row, col =
    unpack(vim.api.nvim_win_get_cursor(0))


  create_edit_buffer(
    win_cmd,
    vim.api.nvim_get_current_buf(),
    row,
    col,
    srow,
    scol,
    erow,
    ecol,
    parser:lang()
  )

end

M.edit_code_block_org = M.edit_code_block
M.edit_code_block_selection = M.edit_code_block_selection

return M
