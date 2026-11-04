-- usage: lua run.lua <health script file> <cases file>. Runs the script like Argo CD does (global obj, returns hs) for every case.
local script = assert(io.open(arg[1])):read("a")
local cases = dofile(arg[2])
local failed = 0
for _, case in ipairs(cases) do
  local name, obj, want = case[1], case[2], case[3]
  -- Only what Argo CD's Lua offers health checks (no string library: string.* fails there, seen on the cluster).
  local env = { obj = obj, ipairs = ipairs, pairs = pairs, type = type, tostring = tostring }
  local chunk = assert(load(script, "health", "t", env))
  local ok, hs = pcall(chunk)
  if not ok then
    failed = failed + 1
    print("FAIL: " .. name .. ": error " .. tostring(hs))
  elseif hs.status ~= want then
    failed = failed + 1
    print("FAIL: " .. name .. ": got " .. tostring(hs.status) .. " (" .. tostring(hs.message) .. "), want " .. want)
  else
    print("ok:   " .. name)
  end
end
print(string.format("%d cases, %d failed", #cases, failed))
os.exit(failed == 0 and 0 or 1)
