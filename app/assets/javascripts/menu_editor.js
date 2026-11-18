(() => {
  const editor = document.querySelector("[data-menu-editor]");
  if (!editor) return;
  const nodes = [...editor.querySelectorAll("[data-item-key]")];
  const notice = document.getElementById("menu-announcement");
  let dragged;
  nodes.forEach(node => {
    const handle = node.querySelector(".menu-drag");
    handle.addEventListener("dragstart", event => {
      dragged = node.dataset.itemKey; editor.classList.add("menu-dragging");
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", dragged);
      notice.textContent = "Drop before another item to save a new draft order.";
    });
    handle.addEventListener("dragend", () => { editor.classList.remove("menu-dragging"); dragged = null; nodes.forEach(item => item.classList.remove("menu-drop")); });
    node.addEventListener("dragover", event => {
      if (!dragged || dragged === node.dataset.itemKey) return;
      event.preventDefault(); event.dataTransfer.dropEffect = "move"; node.classList.add("menu-drop");
    });
    node.addEventListener("dragleave", () => node.classList.remove("menu-drop"));
    node.addEventListener("drop", event => {
      event.preventDefault(); node.classList.remove("menu-drop");
      if (!dragged || dragged === node.dataset.itemKey) return;
      const rows = nodes.map(item => ({key: item.dataset.itemKey, parent_key: item.dataset.parentKey || null, position: Number(item.dataset.position)}));
      const source = rows.find(item => item.key === dragged), target = rows.find(item => item.key === node.dataset.itemKey);
      const descendants = new Set([source.key]);
      for (let pass = 0; pass < rows.length; pass++) rows.forEach(item => { if (descendants.has(item.parent_key)) descendants.add(item.key); });
      if (descendants.has(target.key)) { notice.textContent = "A parent cannot move inside its descendants."; return; }
      const oldParent = source.parent_key;
      rows.filter(item => item.parent_key === oldParent && item.key !== source.key).sort((a,b) => a.position-b.position).forEach((item,index) => item.position=index);
      const inside = event.target.closest("[data-drop-inside]");
      source.parent_key = inside ? target.key : target.parent_key;
      const siblings = rows.filter(item => item.parent_key === source.parent_key && item.key !== source.key).sort((a,b) => a.position-b.position);
      siblings.splice(inside ? siblings.length : siblings.indexOf(target), 0, source); siblings.forEach((item,index) => item.position=index);
      document.getElementById("menu-tree-payload").value = JSON.stringify(rows);
      notice.textContent = "Saving the reordered draft. The server will validate the complete tree.";
      document.getElementById("menu-reorder").requestSubmit();
    });
  });
})();
