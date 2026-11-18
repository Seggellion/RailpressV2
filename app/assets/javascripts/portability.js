(() => {
  "use strict";
  const panel = document.querySelector("[data-portability-status]");
  if (!panel) return;
  const announcement = panel.querySelector("[data-portability-announcement]");
  let previous = "";
  const active = ["receiving", "queued", "inspecting", "staging", "activating", "reversing"];
  if (!active.includes(panel.dataset.portabilityState)) return;
  const poll = async () => {
    try {
      const response = await fetch(panel.dataset.portabilityStatus, {credentials: "same-origin", cache: "no-store", headers: {Accept: "application/json"}});
      if (!response.ok || !response.headers.get("content-type")?.includes("application/json")) throw new Error("unavailable");
      const state = await response.json();
      const message = `${state.state}: ${state.progress} of ${state.total} committed records.${state.failure ? " Processing stopped. Refresh the review to inspect the error." : ""}`;
      if (message !== previous) { announcement.textContent = message; previous = message; }
      const progress = panel.querySelector("progress");
      if (progress && state.total > 0) { progress.max = state.total; progress.value = state.progress; }
      if (active.includes(state.state)) window.setTimeout(poll, 2000);
      else announcement.append(" Refresh the full review for the next available action.");
    } catch (_) {
      announcement.textContent = "Progress unavailable. Reconnect and refresh the review; no completion is assumed.";
    }
  };
  window.setTimeout(poll, 2000);
})();
