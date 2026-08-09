-- Before/after rendering.
--
-- Not a unified diff. Both complete states are shown in full, even for a
-- one-line change, so you can read the function as it was and as it will be
-- rather than reconstructing it from hunks:
--
--   <<< ORIGINAL
--     unchanged line
--   - removed line
--   >>> END ORIGINAL
--
--   <<< UPDATE
--     unchanged line
--   + added line
--   >>> END UPDATE
--
-- Line markers come from vim.diff, so only genuinely changed lines carry a
-- - or +; everything else is shown for context with a leading space.
local M = {}

M.FENCE_OLD_OPEN  = "<<< ORIGINAL"
M.FENCE_OLD_CLOSE = ">>> END ORIGINAL"
M.FENCE_NEW_OPEN  = "<<< UPDATE"
M.FENCE_NEW_CLOSE = ">>> END UPDATE"

--- Which lines changed, via vim.diff's index hunks.
--- Returns two sets keyed by 1-based line number.
local function changed_lines(old_lines, new_lines)
  local removed, added = {}, {}
  local ok, hunks = pcall(vim.diff,
    table.concat(old_lines, "\n") .. "\n",
    table.concat(new_lines, "\n") .. "\n",
    { result_type = "indices", algorithm = "histogram" })
  if not ok or type(hunks) ~= "table" then
    -- no diff available: mark everything, which is still truthful
    for i = 1, #old_lines do removed[i] = true end
    for i = 1, #new_lines do added[i] = true end
    return removed, added
  end
  for _, h in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]
    for i = old_start, old_start + old_count - 1 do
      removed[i] = true
    end
    for i = new_start, new_start + new_count - 1 do
      added[i] = true
    end
  end
  return removed, added
end

--- @param old string  the text being replaced ("" for a pure insertion)
--- @param new string  the replacement
--- @return string     the marked-up block, ready to drop in the transcript
function M.render(old, new)
  local old_lines = (old ~= nil and old ~= "") and vim.split(old, "\n") or {}
  local new_lines = vim.split(new or "", "\n")
  local removed, added = changed_lines(old_lines, new_lines)

  local out = { M.FENCE_OLD_OPEN }
  if #old_lines == 0 then
    out[#out + 1] = "  (new file / appended - nothing replaced)"
  else
    for i, line in ipairs(old_lines) do
      out[#out + 1] = (removed[i] and "- " or "  ") .. line
    end
  end
  out[#out + 1] = M.FENCE_OLD_CLOSE
  out[#out + 1] = ""
  out[#out + 1] = M.FENCE_NEW_OPEN
  for i, line in ipairs(new_lines) do
    out[#out + 1] = (added[i] and "+ " or "  ") .. line
  end
  out[#out + 1] = M.FENCE_NEW_CLOSE

  return table.concat(out, "\n")
end

--- Strips the markers back off, for turning a rendered block into real code.
function M.strip(block)
  local out = {}
  local inside = false
  for _, line in ipairs(vim.split(block, "\n")) do
    if line == M.FENCE_NEW_OPEN then
      inside = true
    elseif line == M.FENCE_NEW_CLOSE then
      inside = false
    elseif inside then
      out[#out + 1] = line:sub(3)
    end
  end
  return table.concat(out, "\n")
end

return M
