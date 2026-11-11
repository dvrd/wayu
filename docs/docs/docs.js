// wayu docs: behavior for the pages under docs/docs/. The pages themselves
// are static HTML rendered from docs/*.md by ./build_it docs (build/markdown);
// this adds the theme toggle, mobile drawer, code highlighting and copy
// buttons, the on-this-page scroll-spy and search across every page.
(function () {
  'use strict';
  var root = document.documentElement;
  var article = document.getElementById('article');
  var pagesEl = document.getElementById('pages');
  var rail = document.getElementById('rail');
  var tocEl = document.getElementById('toc');
  var q = document.getElementById('q');
  var resultsEl = document.getElementById('results');
  var emptyEl = document.getElementById('results-empty');
  var statusEl = document.getElementById('results-status');
  var pagesNav = document.getElementById('pages-nav');
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)');

  // The page list comes from the sidebar the build wrote.
  var PAGES = Array.prototype.map.call(pagesEl.querySelectorAll('a[data-page]'), function (a) {
    return { id: a.dataset.page, title: a.textContent.trim(), url: a.getAttribute('href') };
  });
  var current = pagesEl.querySelector('a[aria-current="page"]');
  var currentId = current ? current.dataset.page : '';

  function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }

  /* ── Theme toggle (shared key with the landing page) ─────────────── */
  var darkMq = window.matchMedia('(prefers-color-scheme: dark)');
  var themeBtn = document.getElementById('theme-btn');
  function isDark() { return root.dataset.theme ? root.dataset.theme === 'dark' : darkMq.matches; }
  function syncThemeLabel() { themeBtn.setAttribute('aria-label', isDark() ? 'Switch to light theme' : 'Switch to dark theme'); }
  themeBtn.addEventListener('click', function () {
    var next = isDark() ? 'light' : 'dark';
    root.dataset.theme = next;
    try { localStorage.setItem('wayu-theme', next); } catch (e) {}
    syncThemeLabel();
  });
  if (darkMq.addEventListener) darkMq.addEventListener('change', syncThemeLabel);
  syncThemeLabel();

  /* ── Mobile drawer ───────────────────────────────────────────────── */
  var menuBtn = document.getElementById('menu-btn');
  var narrow = window.matchMedia('(max-width: 899px)');
  function setDrawer(open, focusSearch) {
    document.body.classList.toggle('nav-open', open);
    menuBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
    menuBtn.setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
    if (open && focusSearch) q.focus({ preventScroll: true });
    if (!open && focusSearch === false) menuBtn.focus();
  }
  menuBtn.addEventListener('click', function () { setDrawer(!document.body.classList.contains('nav-open'), true); });
  document.getElementById('scrim').addEventListener('click', function () { setDrawer(false); });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && document.body.classList.contains('nav-open') && narrow.matches && q.value === '') setDrawer(false, false);
  });

  /* ── An old /docs/?p=<unknown> link ──────────────────────────────── */
  var asked = new URLSearchParams(location.search).get('p');
  if (asked && !currentId) {
    document.title = 'Page not found · wayu docs';
    var state = article.querySelector('.state');
    state.querySelector('.crumb').textContent = '404';
    state.querySelector('h1').textContent = 'No docs page called “' + asked + '”.';
    state.querySelector('p:not(.doc-meta)').textContent = 'It may have been renamed. These are the pages that exist:';
  }

  /* ── Code: highlight.js colors, copy buttons ─────────────────────── */
  var LANG_ALIAS = { zsh: 'bash', sh: 'bash', shell: 'bash', toml: 'ini', conf: 'ini' };
  function highlightAll() {
    if (!window.hljs) return;
    article.querySelectorAll('pre code[class*="language-"]').forEach(function (code) {
      var cls = (code.className.match(/language-(\S+)/) || [])[1] || '';
      var hl = LANG_ALIAS[cls] || cls;
      if (hl && window.hljs.getLanguage(hl)) code.innerHTML = window.hljs.highlight(code.textContent, { language: hl, ignoreIllegals: true }).value;
    });
  }
  highlightAll();

  var copyStatus = document.getElementById('copy-status');
  function announce(msg) { copyStatus.textContent = ''; setTimeout(function () { copyStatus.textContent = msg; }, 60); }
  article.addEventListener('click', function (e) {
    var b = e.target.closest && e.target.closest('.copy-btn');
    if (!b) return;
    var pre = b.parentNode.querySelector('pre');
    var text = pre ? pre.textContent.replace(/\n$/, '') : '';
    // Clipboard refused (permissions, http, old browser): select the code so ⌘C / Ctrl+C works.
    function fallback() {
      if (!pre) return;
      var r = document.createRange(); r.selectNodeContents(pre);
      var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
      announce('Could not copy: the code is selected, press Ctrl+C or ⌘C');
    }
    if (!navigator.clipboard || !navigator.clipboard.writeText) { fallback(); return; }
    navigator.clipboard.writeText(text).then(function () {
      b.classList.add('copied'); announce('Copied');
      clearTimeout(b._t);
      b._t = setTimeout(function () { b.classList.remove('copied'); }, 1600);
    }, fallback);
  });

  /* ── Same-page anchors: smooth scroll and a flash on the target ──── */
  function scrollToHash(hash, smooth) {
    var t = hash && document.getElementById(hash);
    if (!t) return;
    t.scrollIntoView({ behavior: smooth && !reduce.matches ? 'smooth' : 'auto', block: 'start' });
    var flashEl = t.classList.contains('pseudo-h') ? t.firstChild : t;
    flashEl.classList.remove('flash'); void flashEl.offsetWidth; flashEl.classList.add('flash');
  }
  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a');
    if (!a || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    var raw = a.getAttribute('href') || '';
    if (raw.charAt(0) === '#' && a.closest('.md, .toc-list')) {
      e.preventDefault();
      history.pushState(null, '', raw);
      scrollToHash(decodeURIComponent(raw.slice(1)), true);
    }
    if (narrow.matches && a.closest('.side')) setDrawer(false);
  });
  window.addEventListener('popstate', function () { scrollToHash(decodeURIComponent(location.hash.slice(1)), false); });
  if (location.hash) {
    var h = document.getElementById(decodeURIComponent(location.hash.slice(1)));
    if (h) { var f = h.classList.contains('pseudo-h') ? h.firstChild : h; f.classList.add('flash'); }
  }

  /* ── Scroll-spy ──────────────────────────────────────────────────── */
  var tocIds = Array.prototype.map.call(tocEl.querySelectorAll('a[data-id]'), function (a) { return a.dataset.id; });
  var ticking = false;
  function spy() {
    ticking = false;
    if (!tocIds.length) return;
    var active = null, line = parseFloat(getComputedStyle(root).scrollPaddingTop) + 8;
    for (var i = 0; i < tocIds.length; i++) {
      var el = document.getElementById(tocIds[i]);
      if (!el) continue;
      if (el.getBoundingClientRect().top <= line) active = tocIds[i]; else break;
    }
    document.querySelectorAll('.toc-list a').forEach(function (a) {
      var on = a.dataset.id === active;
      a.classList.toggle('active', on);
      if (on) a.setAttribute('aria-current', 'location'); else a.removeAttribute('aria-current');
    });
    // Keep the active entry visible in the right rail.
    var cur = tocEl.querySelector('a.active');
    if (cur && !rail.hidden) {
      var rr = rail.getBoundingClientRect(), cr = cur.getBoundingClientRect();
      if (cr.top < rr.top + 40 || cr.bottom > rr.bottom - 40) rail.scrollTop += cr.top - rr.top - rr.height / 3;
    }
  }
  window.addEventListener('scroll', function () { if (!ticking) { ticking = true; requestAnimationFrame(spy); } }, { passive: true });
  spy();

  /* ── Search across every page ───────────────────────────────────── */
  // Each heading and the text up to the next one, from a page's rendered .md.
  function sections(page, md) {
    var out = [], cur = { id: '', title: page.title, text: '' };
    Array.prototype.forEach.call(md.children, function (node) {
      if (/^H[1-4]$/.test(node.tagName) || node.classList.contains('pseudo-h')) {
        if (cur.text || cur.id) out.push(cur);
        cur = { id: node.tagName === 'H1' ? '' : node.id, title: node.textContent.replace(/#$/, '').replace(/\s+/g, ' ').trim(), text: '' };
      } else {
        cur.text += ' ' + node.textContent;
      }
    });
    out.push(cur);
    out.forEach(function (s) { s.text = s.text.replace(/\s+/g, ' ').trim(); s.page = page; s.hay = (s.title + ' ' + s.text).toLowerCase(); s.titleLc = s.title.toLowerCase(); });
    return out;
  }
  var index = null;
  function loadAll() {
    return index || (index = Promise.all(PAGES.map(function (page) {
      if (page.id === currentId) return sections(page, article.querySelector('.md'));
      return fetch(page.url).then(function (r) {
        if (!r.ok) throw new Error(page.url + ': HTTP ' + r.status);
        return r.text();
      }).then(function (html) {
        var md = new DOMParser().parseFromString(html, 'text/html').querySelector('.md');
        return md ? sections(page, md) : [];
      });
    })).then(function (lists) { return [].concat.apply([], lists); }));
  }

  function highlight(text, terms) {
    var out = esc(text);
    terms.forEach(function (t) {
      if (!t) return;
      out = out.replace(new RegExp('(' + esc(t).replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi'), '<mark>$1</mark>');
    });
    return out;
  }
  function snippet(text, terms) {
    var lc = text.toLowerCase(), at = -1;
    for (var i = 0; i < terms.length && at < 0; i++) at = lc.indexOf(terms[i]);
    if (at < 0) return text.slice(0, 110) + (text.length > 110 ? '…' : '');
    var start = Math.max(0, at - 40), end = Math.min(text.length, at + 90);
    return (start > 0 ? '…' : '') + text.slice(start, end) + (end < text.length ? '…' : '');
  }

  function search(query) {
    var terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    if (!terms.length) {
      resultsEl.hidden = true; emptyEl.hidden = true; pagesNav.hidden = false; statusEl.textContent = '';
      return;
    }
    loadAll().then(function (all) {
      if (q.value.toLowerCase().split(/\s+/).filter(Boolean).join(' ') !== terms.join(' ')) return;
      var hits = [];
      all.forEach(function (s) {
        var score = 0;
        for (var i = 0; i < terms.length; i++) {
          if (s.hay.indexOf(terms[i]) < 0) return;
          if (s.titleLc.indexOf(terms[i]) >= 0) score += 10;
          score += Math.min(5, s.hay.split(terms[i]).length - 1);
        }
        hits.push({ s: s, score: score });
      });
      hits.sort(function (a, b) { return b.score - a.score; });
      hits = hits.slice(0, 40);
      pagesNav.hidden = true;
      emptyEl.hidden = hits.length > 0;
      resultsEl.hidden = hits.length === 0;
      statusEl.textContent = hits.length ? hits.length + (hits.length === 40 ? '+' : '') + ' results' : 'No results';
      resultsEl.innerHTML = hits.map(function (h) {
        var s = h.s;
        return '<li><a href="' + esc(s.page.url + (s.id ? '#' + s.id : '')) + '">' +
          '<span class="r-where">' + esc(s.page.title) + '</span>' +
          '<span class="r-title">' + highlight(s.title, terms) + '</span>' +
          (s.text ? '<span class="r-snip">' + highlight(snippet(s.text, terms), terms) + '</span>' : '') +
          '</a></li>';
      }).join('');
    }, function () {
      pagesNav.hidden = false; resultsEl.hidden = true; emptyEl.hidden = false;
      emptyEl.textContent = 'Search could not load the pages.';
    });
  }
  var debounce;
  q.addEventListener('input', function () { clearTimeout(debounce); debounce = setTimeout(function () { search(q.value); }, 70); });
  q.addEventListener('focus', function () { loadAll(); }, { once: true });
  q.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { var f = resultsEl.querySelector('a'); if (f && !resultsEl.hidden) { e.preventDefault(); f.focus(); } }
    else if (e.key === 'Enter') { var first = resultsEl.querySelector('a'); if (first && !resultsEl.hidden) { e.preventDefault(); first.click(); } }
    else if (e.key === 'Escape') { if (q.value) { e.preventDefault(); e.stopPropagation(); q.value = ''; search(''); } }
  });
  resultsEl.addEventListener('keydown', function (e) {
    var links = Array.prototype.slice.call(resultsEl.querySelectorAll('a'));
    var i = links.indexOf(document.activeElement);
    if (e.key === 'ArrowDown') { e.preventDefault(); (links[i + 1] || links[i]).focus(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); if (i <= 0) q.focus(); else links[i - 1].focus(); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); q.focus(); }
  });
  document.addEventListener('keydown', function (e) {
    var tag = (document.activeElement && document.activeElement.tagName) || '';
    var typing = tag === 'INPUT' || tag === 'TEXTAREA' || (document.activeElement && document.activeElement.isContentEditable);
    if ((e.key === '/' && !typing && !e.metaKey && !e.ctrlKey && !e.altKey) || (e.key.toLowerCase() === 'k' && (e.metaKey || e.ctrlKey))) {
      e.preventDefault();
      if (narrow.matches) setDrawer(true, true); else q.focus();
    }
  });
})();
