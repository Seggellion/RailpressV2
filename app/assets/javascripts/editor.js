(() => {
  const area = document.getElementById("content_body");
  const editor = document.getElementById("visual_editor");
  if (!area || !editor) return;
  const toolbar = document.querySelector(".format-toolbar");
  editor.hidden = false; toolbar.hidden = false; area.hidden = true;
  const sync = () => {
    area.value = editor.innerHTML;
    const outline = document.getElementById("content_outline");
    outline.replaceChildren();
    editor.querySelectorAll("h2,h3,h4").forEach(heading => {
      const item = document.createElement("li"); item.textContent = heading.textContent; outline.append(item);
    });
  };
  editor.addEventListener("input", sync);
  editor.addEventListener("drop", event => event.preventDefault());
  editor.addEventListener("paste", event => {
    event.preventDefault();
    const selection = window.getSelection();
    if (!selection.rangeCount) return;
    const range = selection.getRangeAt(0); range.deleteContents();
    const node = document.createTextNode(event.clipboardData.getData("text/plain")); range.insertNode(node);
    range.setStartAfter(node); range.collapse(true); selection.removeAllRanges(); selection.addRange(range); sync();
  });
  toolbar.querySelectorAll("button").forEach(button => {
    button.addEventListener("mousedown", event => event.preventDefault());
    button.addEventListener("click", () => {
      editor.focus(); document.execCommand(button.dataset.format, false, button.dataset.value || null); sync();
    });
  });
  document.querySelector("[data-editorial-form]").addEventListener("submit", sync);
  sync();
})();
