(() => {
  const protectedRoot = document.getElementById("admin-protected");
  const navigation = document.querySelector("[data-admin-navigation]");
  if (!protectedRoot || !navigation) return;
  const toggle = navigation.querySelector("summary");
  const mobile = matchMedia("(max-width: 52rem)");
  const resize = () => {
    const inside = navigation.contains(document.activeElement);
    navigation.open = !mobile.matches;
    if (mobile.matches && inside) toggle.focus();
  };
  resize();
  mobile.addEventListener("change", resize);
  navigation.addEventListener("keydown", event => {
    if (event.key !== "Escape") return;
    const group = event.target.closest(".admin-nav-group[open]");
    if (group) { group.open = false; group.querySelector("summary").focus(); }
    else if (mobile.matches && navigation.open) { navigation.open = false; toggle.focus(); }
    event.preventDefault();
  });
  document.addEventListener("click", event => {
    if (mobile.matches && navigation.open && !navigation.contains(event.target)) navigation.open = false;
  });
  document.addEventListener("focusin", event => {
    if (mobile.matches && navigation.open && !navigation.contains(event.target)) navigation.open = false;
  });

  const lock = () => { protectedRoot.hidden = true; };
  const login = () => { lock(); location.replace("/login"); };
  let channel;
  try {
    channel = new BroadcastChannel("railpress-session");
    channel.addEventListener("message", event => { if (event.data === "revoked") login(); });
  } catch (_) {}
  addEventListener("storage", event => { if (event.key === "railpress-session-revoked") login(); });
  document.getElementById("admin-signout")?.addEventListener("submit", () => {
    lock();
    channel?.postMessage("revoked");
    try { localStorage.setItem("railpress-session-revoked", crypto.randomUUID()); } catch (_) {}
  });
  addEventListener("pagehide", lock);
  addEventListener("pageshow", event => { if (event.persisted) { lock(); location.reload(); } });
  document.addEventListener("visibilitychange", async () => {
    if (document.visibilityState !== "visible") return;
    lock();
    try {
      const response = await fetch("/admin/session-state", { credentials: "same-origin", cache: "no-store", redirect: "manual" });
      if (response.status !== 204) return login();
      if (response.headers.get("X-Railpress-Session-Binding") !== protectedRoot.dataset.authBinding) return location.reload();
      protectedRoot.hidden = false;
      document.getElementById("admin-session-message").hidden = true;
    } catch (_) { document.getElementById("admin-session-message").hidden = false; }
  });
})();
