// Core-owned progressive enhancement; themes never supply executable assets.
(() => {
  "use strict";
  const disclosures = () => [...document.querySelectorAll("details[data-disclosure]")];
  const close = (item, restoreFocus) => {
    item.querySelectorAll("details[open]").forEach(child => { child.open = false; });
    item.open = false;
    if (restoreFocus) item.querySelector(":scope > summary")?.focus();
  };
  document.addEventListener("keydown", event => {
    if (event.key !== "Escape") return;
    const owner = event.target.closest?.("details[data-disclosure][open]");
    if (owner) { event.preventDefault(); close(owner, true); }
  });
  document.addEventListener("click", event => {
    disclosures().filter(item => item.open && !item.contains(event.target))
      .forEach(item => close(item, false));
  });
  document.addEventListener("focusin", event => {
    disclosures().filter(item => item.open && !item.contains(event.target))
      .forEach(item => close(item, false));
  });
})();
