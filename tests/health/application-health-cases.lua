-- Cases for the Application health check in argocd/values.yaml (run by tests/Test-ApplicationHealth.ps1).
-- Each case: an Application as Argo CD passes it to the script, and the status the check must return.
local OLD = "1111111111111111111111111111111111111111"
local NEW = "2222222222222222222222222222222222222222"
local VALUES = "3333333333333333333333333333333333333333"

local function app(t)
  local obj = {
    metadata = { name = t.name or "platform", annotations = {} },
    spec = { sources = { { targetRevision = t.target or NEW }, { targetRevision = "main", ref = "values" } } },
  }
  if t.gate then obj.metadata.annotations["procure-ai/wave-gate"] = "synced" end
  if t.single then obj.spec = { source = { targetRevision = t.target } } end
  if t.nostatus then return obj end
  obj.status = {
    health = { status = t.health or "Progressing" },
    sync = { status = t.sync or "Synced", revisions = { t.compared or NEW, VALUES }, revision = t.compared },
  }
  if t.op then
    obj.status.operationState = {
      phase = t.op, message = "msg",
      syncResult = { revisions = { t.applied or NEW, VALUES }, revision = t.applied },
    }
  end
  return obj
end

return {
  { "no status yet: Progressing", app { nostatus = true }, "Progressing" },
  { "Argo calls a new app Healthy before its first sync: Progressing", app { health = "Healthy" }, "Progressing" },
  { "sync running: Progressing", app { gate = true, op = "Running" }, "Progressing" },
  { "sync failed (retried): Progressing", app { gate = true, op = "Failed", health = "Degraded" }, "Progressing" },
  { "gated, synced at the target, pods progressing: Healthy", app { gate = true, op = "Succeeded" }, "Healthy" },
  { "gated, OutOfSync: Progressing", app { gate = true, op = "Succeeded", sync = "OutOfSync" }, "Progressing" },
  { "gated, deploy just started (status still at the old revision): Progressing",
    app { gate = true, op = "Succeeded", compared = OLD, applied = OLD }, "Progressing" },
  { "gated, compared at the new revision but the last sync was the old one: Progressing",
    app { gate = true, op = "Succeeded", compared = NEW, applied = OLD }, "Progressing" },
  { "gated but Degraded: Degraded", app { gate = true, op = "Succeeded", health = "Degraded" }, "Degraded" },
  { "not gated, pods progressing: Progressing", app { op = "Succeeded" }, "Progressing" },
  { "not gated, Healthy at the target: Healthy", app { op = "Succeeded", health = "Healthy" }, "Healthy" },
  { "not gated, Healthy but at the old revision: Progressing",
    app { op = "Succeeded", health = "Healthy", compared = OLD, applied = OLD }, "Progressing" },
  { "not gated, Degraded: Degraded", app { op = "Succeeded", health = "Degraded" }, "Degraded" },
  { "not gated, Missing: Progressing", app { op = "Succeeded", health = "Missing" }, "Progressing" },
  { "single source at a chart version (not a SHA), Healthy: Healthy",
    app { single = true, target = "10.11.7", op = "Succeeded", health = "Healthy", compared = "10.11.7", applied = "10.11.7" }, "Healthy" },
  { "single source pinned to a SHA, last sync older: Progressing",
    app { single = true, target = NEW, op = "Succeeded", health = "Healthy", compared = NEW, applied = OLD }, "Progressing" },
}
