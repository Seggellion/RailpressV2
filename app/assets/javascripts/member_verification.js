(() => {
  "use strict";
  const field = document.querySelector("[data-member-verification-token]");
  if (!field || !location.hash) return;
  const fragment = new URLSearchParams(location.hash.slice(1));
  const token = fragment.get("verification_token");
  history.replaceState(null, "", location.pathname);
  if (token && token.length >= 64 && token.length <= 2048) field.value = token;
})();
