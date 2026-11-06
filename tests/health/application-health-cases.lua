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
      operation = { sync = { revisions = { t.opRev or NEW, VALUES } } },
    }
    if t.single then obj.status.operationState.operation = { sync = { revision = t.opRev or t.target } } end
  end
  return obj
end

return {
  { "no status yet: Progressing", app { nostatus = true }, "Progressing" },
  { "Argo calls a new app Healthy before its first sync: Progressing", app { health = "Healthy" }, "Progressing" },
  { "sync running: Progressing", app { gate = true, op = "Running" }, "Progressing" },
  -- Argo CD keeps the phase Running between retry attempts; Failed or Error means every retry is spent (plan 08 ruling 9).
  { "sync retrying after a failed attempt: Progressing", app { gate = true, op = "Running", health = "Healthy" }, "Progressing" },
  { "root is Degraded when a child operation Failed", app { name = "procure-ai", op = "Failed", health = "Healthy" }, "Degraded" },
  { "a Failed sync at the target (no resources applied, OutOfSync): Degraded",
    app { name = "procure-ai", op = "Failed", health = "Healthy", sync = "OutOfSync", applied = OLD, opRev = NEW }, "Degraded" },
  { "compared at the new target, the Failed operation still the earlier target's: Progressing",
    app { name = "procure-ai", op = "Failed", health = "Healthy", sync = "OutOfSync", applied = OLD, opRev = OLD }, "Progressing" },
  { "single source pinned to a SHA, the Failed operation an earlier SHA's: Progressing",
    app { single = true, target = NEW, op = "Failed", health = "Healthy", compared = NEW, opRev = OLD }, "Progressing" },
  { "single source pinned to a SHA, sync Failed at it: Degraded",
    app { single = true, target = NEW, op = "Failed", health = "Healthy", compared = NEW, opRev = NEW }, "Degraded" },
  { "a Failed sync of an earlier target, the new target not compared yet: Progressing",
    app { name = "procure-ai", op = "Failed", health = "Healthy", compared = OLD, applied = OLD }, "Progressing" },
  { "single source at a chart version, sync Failed: Degraded",
    app { single = true, target = "10.11.7", op = "Failed", health = "Healthy", compared = "10.11.7" }, "Degraded" },
  { "a child operation Error: Degraded", app { op = "Error", health = "Healthy" }, "Degraded" },
  { "gated, sync Failed: Degraded (the gate does not hide it)", app { gate = true, op = "Failed", health = "Degraded" }, "Degraded" },
  { "gated, synced at the target, pods progressing: Healthy", app { gate = true, op = "Succeeded" }, "Healthy" },
  { "gated, OutOfSync: Progressing", app { gate = true, op = "Succeeded", sync = "OutOfSync" }, "Progressing" },
  { "gated, deploy just started (status still at the old revision): Progressing",
    app { gate = true, op = "Succeeded", compared = OLD, applied = OLD }, "Progressing" },
  -- An app-only deploy renders the platform's manifests unchanged: Argo CD compares it at the new revision, finds it Synced and
  -- starts no sync, so the last sync stays at the old revision. That must open the gate (it once deadlocked the root on a cluster).
  { "gated, Synced at the new revision without a new sync (nothing changed): Healthy",
    app { gate = true, op = "Succeeded", compared = NEW, applied = OLD }, "Healthy" },
  { "gated, compared at the new revision and OutOfSync (sync not started yet): Progressing",
    app { gate = true, op = "Succeeded", compared = NEW, applied = OLD, sync = "OutOfSync" }, "Progressing" },
  { "gated, compared at the new revision, sync running: Progressing",
    app { gate = true, op = "Running", compared = NEW, applied = OLD }, "Progressing" },
  { "gated but Degraded: Degraded", app { gate = true, op = "Succeeded", health = "Degraded" }, "Degraded" },
  { "not gated, pods progressing: Progressing", app { op = "Succeeded" }, "Progressing" },
  { "not gated, Healthy at the target: Healthy", app { op = "Succeeded", health = "Healthy" }, "Healthy" },
  { "not gated, Healthy but at the old revision: Progressing",
    app { op = "Succeeded", health = "Healthy", compared = OLD, applied = OLD }, "Progressing" },
  { "not gated, Degraded: Degraded", app { op = "Succeeded", health = "Degraded" }, "Degraded" },
  { "not gated, Missing: Progressing", app { op = "Succeeded", health = "Missing" }, "Progressing" },
  { "single source at a chart version (not a SHA), Healthy: Healthy",
    app { single = true, target = "10.11.7", op = "Succeeded", health = "Healthy", compared = "10.11.7", applied = "10.11.7" }, "Healthy" },
  { "single source pinned to a SHA, compared at the old one: Progressing",
    app { single = true, target = NEW, op = "Succeeded", health = "Healthy", compared = OLD, applied = OLD }, "Progressing" },
  { "single source pinned to a SHA, Synced at it without a new sync: Healthy",
    app { single = true, target = NEW, op = "Succeeded", health = "Healthy", compared = NEW, applied = OLD }, "Healthy" },
}
