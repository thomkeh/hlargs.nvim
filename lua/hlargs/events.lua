local M = {}
local parser = require 'hlargs.parse'
local config = require 'hlargs.config'.opts
local util = require 'hlargs.util'
local bufdata = require 'hlargs.bufdata'
local paint = require 'hlargs.paint'

-- TODO volar (se usa en disable)
local buf_data = {}
local enabled = false

-- TODO volar (se usa en disable)
local function clear_all(bufnr, nss)
  for k,ns in ipairs(nss) do
    if ns then
      paint.clear(bufnr, ns)
    end
  end
end

local function paint_nodes(bufnr, ns, node_group)
  if not node_group then return end
  for i, node in ipairs(node_group) do
    paint(bufnr, ns, node)
  end
end

function find_and_paint_iteration(bufnr, task, co)
  vim.defer_fn(function()
    if coroutine.status(co) ~= "dead" and not task.stop then
      local marks_ns = bufdata.get(bufnr).marks_ns
      local running, arg_nodes, usage_nodes = coroutine.resume(co, bufnr, marks_ns, task.mark)
      if running then
        if config.paint_arg_declarations then
          paint_nodes(bufnr, task.ns, arg_nodes)
        end
        paint_nodes(bufnr, task.ns, usage_nodes)
        find_and_paint_iteration(bufnr, task, co)
      end
    else
      if not vim.api.nvim_buf_is_valid(bufnr) then
        bufdata.delete_data(bufnr)
      else
        if not task.stop then
          bufdata.end_task(bufnr, task)
        end
      end
    end
  end, config.performance.parse_delay)
end

function is_excluded(bufnr)
  local filetype = vim.fn.getbufvar(bufnr, '&filetype')
  return util.contains(config.excluded_filetypes, filetype)
end

function M.find_and_paint_nodes(bufnr, mark)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not enabled or is_excluded(bufnr) then return end

  local task = bufdata.new_task(bufnr, mark)
  if not task then return end

  local co = coroutine.create(parser.get_nodes_to_paint)
  find_and_paint_iteration(bufnr, task, co)
end

local function schedule_partial_repaints(bufnr, buf_data)
  buf_data.ranges_to_parse = util.merge_ranges(bufnr, buf_data.marks_ns, buf_data.ranges_to_parse)

  if config.performance.max_concurrent_partial_parses ~= 0 and
    #buf_data.ranges_to_parse + #buf_data.tasks == config.performance.max_concurrent_partial_parses
  then
    buf_data.ranges_to_parse = {}
    M.schedule_total_repaint(bufnr)
    return
  end

  for _, r in ipairs(buf_data.ranges_to_parse) do
    M.find_and_paint_nodes(bufnr, r)
  end
  buf_data.ranges_to_parse = {}
end

function M.add_range_to_queue(bufnr, from, to)
  if not enabled or is_excluded(bufnr) then return end

  local buf_data = bufdata.get(bufnr)
  local range = paint.set_extmark(bufnr, buf_data.marks_ns, from, 0, to, 0)
  table.insert(buf_data.ranges_to_parse, range)

  if buf_data.debouncers.range_queue then
    vim.loop.timer_stop(buf_data.debouncers.range_queue)
  end
  local debounce_time = config.performance.debounce.partial_parse
  if string.sub(vim.api.nvim_get_mode().mode, 1, 1) == 'i' then
    -- Higher debouncing for insert mode
    debounce_time = config.performance.debounce.partial_insert_mode
  end
  -- TODO configurable debounce times
  buf_data.debouncers.range_queue = vim.defer_fn(function ()
    schedule_partial_repaints(bufnr, buf_data)
  end, debounce_time)
end

function M.schedule_total_repaint(bufnr)
  if not enabled or is_excluded(bufnr) then return end

  local buf_data = bufdata.get(bufnr)
  if buf_data.debouncers.total_parse then
    vim.loop.timer_stop(buf_data.debouncers.total_parse)
  end
  buf_data.debouncers.total_parse = vim.defer_fn(function ()
    M.find_and_paint_nodes(bufnr)
  end, config.performance.debounce.total_parse)
end

function M.buf_enter(bufnr)
  if is_excluded(bufnr) then return end

  M.schedule_total_repaint(bufnr)

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(ev, bufnr, _, from, old_to, to)
      M.add_range_to_queue(bufnr, from, to)
    end,
    on_reload = function (ev, bufnr)
      M.schedule_total_repaint(bufnr)
    end
  })
end

function M.enable()
  if not enabled then
    enabled = true
    vim.cmd([[
      augroup Hlargs
        autocmd!
        autocmd BufEnter * lua require('hlargs.events').buf_enter(tonumber(vim.fn.expand("<abuf>")))
      augroup end]])
    local bufs = vim.api.nvim_list_bufs()
    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_loaded(b) then
        buf_enter(b)
      end
    end
  end
end

function M.disable()
  if enabled then
    enabled = false
    pcall(vim.cmd, "autocmd! Hlargs")
    pcall(vim.cmd, "augroup! Hlargs")
    -- TODO
    for bufnr, data in ipairs(buf_data) do
      for _, stopper in pairs(data.coroutines.stoppers) do
        stopper.stop = true
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        clear_all(bufnr, data.namespaces.to_clean)
        data.namespaces.to_clean = {}
      end
      buf_data[bufnr] = nil
    end
  end
end

return M
