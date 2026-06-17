--[[
floating-sidebar-toc.lua

Pandoc Lua filter that transforms the Pandoc's generated table of contents
into a collapsible left floating sidebar in standalone HTML output.

Usage:

pandoc -s --toc --lua-filter floating-sidebar-toc.lua -o output.html input.md

(Works also with YAML metadata that specifies custom "maxwidth".)

---

SPDX-License-Identifier: 0BSD

Copyright (C) 2026 by oko256
(https://github.com/oko256/pandoc-floating-sidebar-toc)

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
/* sidebar width can be customized with these variables:
   --sst-w      : width of sidebar in narrow mode
   --sst-wide-w : width of sidebar in wide mode
*/
:root { --sst-w: 18rem; --sst-wide-w: min(42rem, 92vw); }

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
  transition: width 0.18s ease, transform 0.18s ease, background 0.18s ease;
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

/* narrow TOC: long headings get clipped */
#TOC a {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* wide TOC: over the body content */
html.sst-open.sst-wide #TOC {
  width: var(--sst-wide-w);
  background: rgba(245, 245, 245, 0.94);
  box-shadow: 4px 0 16px rgba(0, 0, 0, 0.18);
}
html.sst-open.sst-wide #TOC a {
  white-space: normal;
  overflow: visible;
}

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

#sst-collapse, #sst-widen { flex: 0 0 auto; font-size: 1rem; }

#sst-menu {
  position: fixed;
  top: 0.5rem;
  left: 0.5rem;
  z-index: 1100;
  font-size: 1.1rem;
  padding: 0.2rem 0.5rem;
}
html.sst-open #sst-menu { display: none; }

/* on small screen: overlay the content with narrow TOC as well */
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
  #sst-menu, #sst-widen { display: none; }
}
</style>
]]

local js = [[
<script>
(function () {
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

    var widen = document.createElement('button');
    widen.id = 'sst-widen';
    widen.className = 'sst-btn';
    widen.type = 'button';
    header.appendChild(collapse);
    header.appendChild(title);
    header.appendChild(widen);
    toc.insertBefore(header, toc.firstChild);

    function syncWiden() {
      var wide = root.classList.contains('sst-wide');
      widen.innerHTML = wide ? '◀' : '▶';
      widen.setAttribute('aria-label', wide ? 'Narrow sidebar' : 'Widen sidebar');
      widen.setAttribute('aria-pressed', wide ? 'true' : 'false');
    }

    function syncMenu() {
      var open = root.classList.contains('sst-open');
      menu.setAttribute('aria-expanded', open ? 'true' : 'false');
      menu.setAttribute('aria-label',
        open ? 'Hide table of contents' : 'Show table of contents');
    }

    function setOpen(open) {
      root.classList.toggle('sst-open', open);
      if (!open) root.classList.remove('sst-wide');
      syncMenu();
      syncWiden();
    }

    menu.addEventListener('click', function () { setOpen(true); });
    collapse.addEventListener('click', function () { setOpen(false); });

    widen.addEventListener('click', function () {
      root.classList.toggle('sst-wide');
      syncWiden();
    });

    // Clicking outside the sidebar while wide collapses it back to narrow.
    document.addEventListener('click', function (e) {
      if (root.classList.contains('sst-wide') && !toc.contains(e.target)) {
        root.classList.remove('sst-wide');
        syncWiden();
      }
    });

    // Initial state: narrow sidebar open.
    root.classList.add('sst-open');
    syncMenu();
    syncWiden();
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
