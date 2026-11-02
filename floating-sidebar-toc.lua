--[[
floating-sidebar-toc.lua

Pandoc Lua filter that transforms the Pandoc's generated table of contents
into a collapsible left floating sidebar in standalone HTML output.

Usage:

pandoc -s --toc --lua-filter floating-sidebar-toc.lua -o output.html input.md

(Works also with YAML metadata that specifies custom "maxwidth".)

---

SPDX-License-Identifier: 0BSD

Copyright (C) 2026 Olli Kokko <https://github.com/oko256/pandoc-floating-sidebar-toc>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
--]]

local css = [[
<style>
/* default (initial) sidebar width can be customized with this variable:
   --sst-w : width of sidebar
   The user can drag the sidebar's right edge to resize it; the chosen width
   is remembered (when the browser allows localStorage). Double-click the edge
   to reset back to the default width.
*/
:root { --sst-w: 18rem; }

html { box-sizing: border-box; transition: padding-left 0.18s ease; }
html.sst-open { padding-left: var(--sst-w); }

#TOC {
  position: fixed;
  top: 0;
  left: 0;
  height: 100vh;
  width: var(--sst-w);
  box-sizing: border-box;
  padding: 0.75rem 0.75rem 1rem;
  overflow-y: auto;
  overflow-x: hidden;
  background: #f5f5f5;
  border-right: 1px solid #d9d9d9;
  font-size: 0.85rem;
  line-height: 1.35;
  z-index: 1000;
  transition: width 0.18s ease, transform 0.18s ease;
}

/* collapsed TOC off-screen */
html:not(.sst-open) #TOC { transform: translateX(-100%); }

/* compact list styling */
#TOC ul { list-style: none; margin: 0; padding-left: 0.85rem; }
#TOC > ul { padding-left: 0; }
#TOC li { margin: 0.05rem 0; }
#TOC a {
  display: block;
  padding: 0.1rem 0.25rem;
  color: #222;
  text-decoration: none;
  border-radius: 3px;
}
#TOC a:hover { background: rgba(0, 0, 0, 0.07); }

/* long headings get clipped (full text is shown as a tooltip) */
#TOC a {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* drag handle on the right edge of the sidebar */
#sst-resizer {
  position: fixed;
  top: 0;
  left: var(--sst-w);
  width: 6px;
  height: 100vh;
  margin-left: -3px;
  cursor: col-resize;
  z-index: 1001;
  touch-action: none;
  background: transparent;
  transition: background 0.15s ease, left 0.18s ease;
}
#sst-resizer:hover,
#sst-resizer:focus-visible,
html.sst-resizing #sst-resizer { background: rgba(0, 0, 0, 0.15); }
#sst-resizer:focus-visible { outline: none; }
html:not(.sst-open) #sst-resizer { display: none; }

/* while dragging: follow the pointer immediately, don't select text */
html.sst-resizing,
html.sst-resizing #TOC,
html.sst-resizing #sst-resizer { transition: none; }
html.sst-resizing { cursor: col-resize; user-select: none; -webkit-user-select: none; }

.sst-header {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin: 0 0 0.5rem;
  padding-bottom: 0.4rem;
  border-bottom: 1px solid #d9d9d9;
}
.sst-title {
  flex: 1 1 auto;
  font-weight: 600;
  font-size: 0.9rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sst-btn {
  font: inherit;
  line-height: 1;
  cursor: pointer;
  border: 1px solid #c2c2c2;
  background: #fff;
  color: #222;
  border-radius: 4px;
  padding: 0.25rem 0.45rem;
}
.sst-btn:hover { background: #eaeaea; }

#sst-collapse { flex: 0 0 auto; font-size: 1rem; }

#sst-menu {
  position: fixed;
  top: 0.5rem;
  left: 0.5rem;
  z-index: 1100;
  font-size: 1.1rem;
  padding: 0.2rem 0.5rem;
}
html.sst-open #sst-menu { display: none; }

/* on small screen: overlay the content with the TOC */
@media (max-width: 40rem) {
  html.sst-open { padding-left: 0; }
  #TOC { box-shadow: 4px 0 16px rgba(0, 0, 0, 0.18); }
}

/* remove the TOC customizations when printing */
@media print {
  #TOC { position: static; height: auto; width: auto; overflow: visible;
         border: 0; background: transparent; padding: 0; transform: none; }
  #TOC a { white-space: normal; }
  html.sst-open { padding-left: 0; }
  #sst-menu, #sst-resizer { display: none; }
}
</style>
]]

local js = [[
<script>
(function () {
  var STORAGE_KEY = 'sst-width';
  var MIN_W = 160;          // px
  var MIN_CONTENT_W = 200;  // px of content that always stays visible

  function init() {
    var toc = document.getElementById('TOC');
    if (!toc) return; // no TOC: do nothing

    var body = document.body;
    var root = document.documentElement;

    var menu = document.createElement('button');
    menu.id = 'sst-menu';
    menu.className = 'sst-btn';
    menu.type = 'button';
    menu.innerHTML = '☰';
    menu.setAttribute('aria-label', 'Show table of contents');
    menu.setAttribute('aria-expanded', 'false');
    body.appendChild(menu);

    var header = document.createElement('div');
    header.className = 'sst-header';

    var collapse = document.createElement('button');
    collapse.id = 'sst-collapse';
    collapse.className = 'sst-btn';
    collapse.type = 'button';
    collapse.innerHTML = '☰';
    collapse.setAttribute('aria-label', 'Hide table of contents');

    var title = document.createElement('span');
    title.className = 'sst-title';
    title.textContent = toc.getAttribute('aria-label') || 'Contents';

    header.appendChild(collapse);
    header.appendChild(title);
    toc.insertBefore(header, toc.firstChild);

    // Show the full heading text on hover, since long ones get clipped.
    var links = toc.querySelectorAll('a');
    for (var i = 0; i < links.length; i++) {
      if (!links[i].title) links[i].title = links[i].textContent.trim();
    }

    var resizer = document.createElement('div');
    resizer.id = 'sst-resizer';
    resizer.tabIndex = 0;
    resizer.setAttribute('role', 'separator');
    resizer.setAttribute('aria-orientation', 'vertical');
    resizer.setAttribute('aria-controls', 'TOC');
    resizer.setAttribute('aria-label', 'Resize table of contents');
    resizer.title = 'Drag to resize, double-click to reset';
    body.appendChild(resizer);

    var defaultWidth = toc.offsetWidth; // from the --sst-w in CSS
    var width = defaultWidth;
    var custom = false; // has the user chosen a width?

    function maxWidth() {
      var w = window.innerWidth;
      return Math.max(MIN_W, Math.min(w * 0.75, w - MIN_CONTENT_W));
    }

    function syncAria() {
      resizer.setAttribute('aria-valuemin', String(MIN_W));
      resizer.setAttribute('aria-valuemax', String(Math.round(maxWidth())));
      resizer.setAttribute('aria-valuenow', String(Math.round(width)));
    }

    function setWidth(px) {
      width = Math.round(Math.min(Math.max(px, MIN_W), maxWidth()));
      custom = true;
      root.style.setProperty('--sst-w', width + 'px');
      syncAria();
    }

    function saveWidth() {
      try { localStorage.setItem(STORAGE_KEY, String(width)); } catch (e) {}
    }

    function resetWidth() {
      custom = false;
      width = defaultWidth;
      root.style.removeProperty('--sst-w');
      try { localStorage.removeItem(STORAGE_KEY); } catch (e) {}
      syncAria();
    }

    // Restore previously chosen width.
    try {
      var saved = parseInt(localStorage.getItem(STORAGE_KEY), 10);
      if (saved > 0) setWidth(saved);
    } catch (e) {}
    syncAria();

    // Dragging (mouse, touch and pen via Pointer Events).
    var dragging = false, startX = 0, startW = 0, pendingX = null, frame = 0;

    function applyPending() {
      frame = 0;
      if (pendingX !== null) setWidth(startW + (pendingX - startX));
    }

    resizer.addEventListener('pointerdown', function (e) {
      if (e.button !== 0) return;
      e.preventDefault();
      dragging = true;
      startX = e.clientX;
      startW = toc.offsetWidth;
      pendingX = null;
      resizer.setPointerCapture(e.pointerId);
      root.classList.add('sst-resizing');
    });

    resizer.addEventListener('pointermove', function (e) {
      if (!dragging) return;
      pendingX = e.clientX;
      // At most one layout update per frame: long documents reflow slowly.
      if (!frame) frame = requestAnimationFrame(applyPending);
    });

    function endDrag(e) {
      if (!dragging) return;
      dragging = false;
      if (frame) { cancelAnimationFrame(frame); applyPending(); }
      if (resizer.hasPointerCapture(e.pointerId)) {
        resizer.releasePointerCapture(e.pointerId);
      }
      root.classList.remove('sst-resizing');
      if (pendingX !== null) saveWidth();
    }
    resizer.addEventListener('pointerup', endDrag);
    resizer.addEventListener('pointercancel', endDrag);

    resizer.addEventListener('dblclick', resetWidth);

    resizer.addEventListener('keydown', function (e) {
      var step = e.shiftKey ? 64 : 16;
      var w;
      switch (e.key) {
        case 'ArrowLeft':  w = width - step; break;
        case 'ArrowRight': w = width + step; break;
        case 'Home':       w = MIN_W; break;
        case 'End':        w = maxWidth(); break;
        default: return;
      }
      e.preventDefault();
      setWidth(w);
      saveWidth();
    });

    // Keep a user-chosen width within limits when the window shrinks.
    window.addEventListener('resize', function () {
      if (custom && width > maxWidth()) setWidth(width);
      syncAria();
    });

    function syncMenu() {
      var open = root.classList.contains('sst-open');
      menu.setAttribute('aria-expanded', open ? 'true' : 'false');
      menu.setAttribute('aria-label',
        open ? 'Hide table of contents' : 'Show table of contents');
    }

    function setOpen(open) {
      root.classList.toggle('sst-open', open);
      syncMenu();
    }

    menu.addEventListener('click', function () { setOpen(true); });
    collapse.addEventListener('click', function () { setOpen(false); });

    // Initial state: sidebar open.
    root.classList.add('sst-open');
    syncMenu();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
</script>
]]

function Pandoc(doc)
  if not FORMAT:match('html') then
    return nil -- only meaningful for HTML output
  end
  table.insert(doc.blocks, 1, pandoc.RawBlock('html', css))
  table.insert(doc.blocks, pandoc.RawBlock('html', js))
  return doc
end
