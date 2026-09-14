/* ══════════════════════════════════════════════════════════
   柴柴 ChaiChai — script.js
   ══════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var $  = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };

  /* ── Toast ──────────────────────────────────────────── */
  var toastEl = $('#toast'), toastTimer;
  function toast(msg) {
    if (!toastEl) return;
    toastEl.textContent = msg;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.remove('show'); }, 2200);
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (res, rej) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.cssText = 'position:fixed;top:-1000px;opacity:0';
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(ta);
      ok ? res() : rej();
    });
  }

  /* ── 年齡：用生日自動算，不寫死 ──────────────────────── */
  (function () {
    var els = $$('#age, #age2');
    if (!els.length) return;
    var b = new Date(2006, 2, 15);            // 2006/03/15（月份從 0 起算）
    var now = new Date();
    var age = now.getFullYear() - b.getFullYear();
    var m = now.getMonth() - b.getMonth();
    if (m < 0 || (m === 0 && now.getDate() < b.getDate())) age--;
    els.forEach(function (el) { el.textContent = age; });
  })();

  /* ── 星空 ───────────────────────────────────────────── */
  (function () {
    var c = $('#starfield');
    if (!c || !c.getContext) return;
    var ctx = c.getContext('2d');
    var w = 0, h = 0, stars = [], raf = null;

    function seed() {
      var n = Math.max(40, Math.min(130, Math.round((w * h) / 13000)));
      stars = [];
      for (var i = 0; i < n; i++) {
        var warm = Math.random() < 0.18;
        stars.push({
          x: Math.random() * w,
          y: Math.random() * h,
          r: Math.random() * 1.15 + 0.25,
          a: Math.random() * 0.45 + 0.12,
          sp: Math.random() * 0.7 + 0.25,
          ph: Math.random() * Math.PI * 2,
          vy: warm ? -(Math.random() * 0.05 + 0.015) : 0,
          warm: warm
        });
      }
    }

    function resize() {
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = c.clientWidth; h = c.clientHeight;
      c.width = Math.round(w * dpr); c.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      seed();
      if (reduce) draw(0);
    }

    function draw(t) {
      ctx.clearRect(0, 0, w, h);
      for (var i = 0; i < stars.length; i++) {
        var s = stars[i];
        if (s.vy) { s.y += s.vy; if (s.y < -4) { s.y = h + 4; s.x = Math.random() * w; } }
        var tw = reduce ? 1 : (0.6 + 0.4 * Math.sin(t / 1000 * s.sp + s.ph));
        ctx.globalAlpha = s.a * tw;
        ctx.fillStyle = s.warm ? '#ffc987' : '#cfdcff';
        ctx.beginPath();
        ctx.arc(s.x, s.y, s.r, 0, 6.2832);
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    }

    function loop(t) { draw(t); raf = requestAnimationFrame(loop); }
    function start() { if (!reduce && raf === null) raf = requestAnimationFrame(loop); }
    function stop() { if (raf !== null) { cancelAnimationFrame(raf); raf = null; } }

    resize();
    start();

    /* 只有首屏看得到星空，捲過去就停掉，手機才不會一直耗電 */
    var hero = document.querySelector('.hero');
    if (hero && 'IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) {
        entries[0].isIntersecting ? start() : stop();
      }, { threshold: 0 }).observe(hero);
    }

    var rt;
    window.addEventListener('resize', function () {
      clearTimeout(rt);
      rt = setTimeout(resize, 180);
    });
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) stop();
      else if (!hero || hero.getBoundingClientRect().bottom > 0) start();
    });
  })();

  /* ── 進場動畫 ───────────────────────────────────────── */
  (function () {
    var targets = $$('.sec__head, .intro, .ava, .intro__t, .traits, .talk, .lede, .tags, .save, .sub, .roster, .chart, .wall .ph, .dir__col, .quote, .quote__btns');
    if (!targets.length) return;

    if (!('IntersectionObserver' in window)) return;

    targets.forEach(function (el) { el.classList.add('rv'); });

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        var d = parseInt(e.target.getAttribute('data-d') || '0', 10);
        setTimeout(function () { e.target.classList.add('in'); }, d);
        io.unobserve(e.target);
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });

    // 照片牆錯開一點，比較有手感
    $$('.wall .ph').forEach(function (el, i) { el.setAttribute('data-d', String(i * 70)); });
    $$('.dir__col').forEach(function (el, i) { el.setAttribute('data-d', String(i * 90)); });

    targets.forEach(function (el) { io.observe(el); });
  })();

  /* ── 燈桿：目前章節亮燈 ─────────────────────────────── */
  (function () {
    var links = $$('.pole a[data-lamp]');
    if (!links.length || !('IntersectionObserver' in window)) return;

    var map = {};
    links.forEach(function (a) { map[a.getAttribute('data-lamp')] = a; });

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        links.forEach(function (a) { a.classList.remove('is-on'); });
        var a = map[e.target.id];
        if (a) a.classList.add('is-on');
      });
    }, { rootMargin: '-45% 0px -50% 0px', threshold: 0 });

    Object.keys(map).forEach(function (id) {
      var sec = document.getElementById(id);
      if (sec) io.observe(sec);
    });
  })();

  /* ── 柴柴語錄 ───────────────────────────────────────── */
  (function () {
    var QUOTES = [
      '說個小知識，其實你只要錢多，你就會很有錢。',
      '你不睡覺，就會想睡覺。',
      '熬夜不會變強，只會變醜。',
      '當兵教會我一件事：等。',
      '人生就像更新 Windows，永遠在重開機。',
      '沒有人回你訊息，是因為沒有人回你訊息。',
      '打不贏通常是因為對面比較強。',
      '只要你不點開，那個紅點就會一直在。',
      '肚子餓就去吃東西，吃完通常就不餓了。',
      '你現在還醒著，是因為你還沒睡著。'
    ];

    var text = $('#quote-text');
    var roll = $('#btn-roll');
    var copy = $('#btn-copy');
    if (!text) return;

    var last = 0;
    text.textContent = QUOTES[0];

    function next() {
      var i = last;
      while (QUOTES.length > 1 && i === last) i = Math.floor(Math.random() * QUOTES.length);
      last = i;
      text.classList.add('swap');
      setTimeout(function () {
        text.textContent = QUOTES[i];
        text.classList.remove('swap');
      }, reduce ? 0 : 260);
    }

    if (roll) roll.addEventListener('click', next);

    if (copy) copy.addEventListener('click', function () {
      copyText(text.textContent).then(
        function () { toast('複製好了，拿去用'); },
        function () { toast('複製失敗，手動選一下吧'); }
      );
    });
  })();

  /* ── 社群連結：待補 / 複製 ID ───────────────────────── */
  (function () {
    $$('.dir a[data-pending]').forEach(function (a) {
      a.addEventListener('click', function (e) {
        e.preventDefault();
        toast('這個連結還沒補上');
      });
    });

    $$('.dir a[data-copy]').forEach(function (a) {
      a.addEventListener('click', function (e) {
        e.preventDefault();
        var v = a.getAttribute('data-copy');
        copyText(v).then(
          function () { toast('已複製：' + v); },
          function () { toast('複製失敗：' + v); }
        );
      });
    });
  })();

  /* ── 照片燈箱 ───────────────────────────────────────── */
  (function () {
    var lb = $('#lightbox'), lbImg = $('#lb-img'), lbCap = $('#lb-cap');
    var close = $('.lb__close');
    if (!lb || !lbImg) return;

    var opener = null;

    function open(fig) {
      var img = $('img', fig);
      var cap = $('figcaption', fig);
      if (!img) return;
      lbImg.src = img.currentSrc || img.src;
      lbImg.alt = img.alt || '';
      lbCap.textContent = cap ? cap.textContent : '';
      lb.hidden = false;
      lb.setAttribute('role', 'dialog');
      lb.setAttribute('aria-modal', 'true');
      document.body.style.overflow = 'hidden';
      opener = fig;
      if (close) close.focus();
    }

    function shut() {
      lb.hidden = true;
      lbImg.src = '';
      document.body.style.overflow = '';
      if (opener) { opener.focus && opener.focus(); opener = null; }
    }

    /* 燈箱開著時把 Tab 鎖在裡面，不然鍵盤使用者會跑到背景迷路 */
    lb.addEventListener('keydown', function (e) {
      if (e.key !== 'Tab' || lb.hidden) return;
      var focusable = $$('button, [href], input, [tabindex]:not([tabindex="-1"])', lb);
      if (!focusable.length) return;
      var first = focusable[0], last = focusable[focusable.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    });

    $$('.wall .ph').forEach(function (fig) {
      fig.setAttribute('tabindex', '0');
      fig.setAttribute('role', 'button');
      fig.addEventListener('click', function () { open(fig); });
      fig.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(fig); }
      });
    });

    lb.addEventListener('click', function (e) {
      if (e.target === lb || e.target === close || e.target === lbCap) shut();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !lb.hidden) shut();
    });
  })();

  /* ── 音遊譜面：真的可以滑動時才顯示提示 ─────────────── */
  (function () {
    var chart = $('.chart'), scroll = $('.chart__scroll');
    if (!chart || !scroll) return;
    function check() {
      chart.classList.toggle('is-scrollable', scroll.scrollWidth - scroll.clientWidth > 4);
    }
    check();
    window.addEventListener('resize', check);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(check);
    window.addEventListener('load', check);
  })();

  /* ── 彩蛋：戳頭像 / 戳本人照片 ─────────────────────── */
  (function () {
    var bubble = $('#bubble');
    if (!bubble) return;

    var LINES = {
      ava: [
        '汪。',
        '你點我幹嘛啦。',
        '再點我要開始收摸頭費了。',
        '好啦我知道我很可愛，不用一直確認。',
        '第五下了，你手很閒喔。',
        '再一下我就把你送去站哨。',
        '……算了，你高興就好，繼續。'
      ],
      photo: [
        '看什麼看。',
        '對，本人就長這樣。',
        '你再點，我也不會變帥。',
        '這張已經是我最好看的一張了。',
        '拍照那天風超大，別問。',
        '你比我還認真在看這張照片。',
        '行了吧，往下看啦。'
      ]
    };

    var count = { ava: 0, photo: 0 };
    var timer;

    function pop(el, kind) {
      var lines = LINES[kind] || LINES.ava;
      var i = Math.min(count[kind]++, lines.length - 1);
      var r = el.getBoundingClientRect();

      bubble.textContent = lines[i];
      bubble.hidden = false;
      bubble.classList.remove('show');

      /* 先量尺寸再定位，避免泡泡跑出畫面 */
      var bw = bubble.offsetWidth, bh = bubble.offsetHeight;
      var left = Math.min(Math.max(12, r.left + r.width * 0.5 - 20), window.innerWidth - bw - 12);
      var top  = r.top - bh - 12;
      if (top < 12) top = Math.min(r.bottom + 12, window.innerHeight - bh - 12);
      bubble.style.left = Math.round(left) + 'px';
      bubble.style.top  = Math.round(top) + 'px';

      requestAnimationFrame(function () { bubble.classList.add('show'); });
      clearTimeout(timer);
      timer = setTimeout(function () {
        bubble.classList.remove('show');
        setTimeout(function () { bubble.hidden = true; }, 300);
      }, 2400);
    }

    $$('[data-egg]').forEach(function (el) {
      var kind = el.getAttribute('data-egg');
      function fire(e) {
        if (e) e.preventDefault();
        pop(el, kind);
        if (el.classList.contains('ava')) {
          el.classList.remove('is-poked');
          void el.offsetWidth;
          el.classList.add('is-poked');
        }
      }
      el.addEventListener('click', fire);
      el.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') fire(e);
      });
    });
  })();

  /* ── 分享這個頁面 ───────────────────────────────────── */
  (function () {
    var btn = $('#btn-share');
    if (!btn) return;
    btn.addEventListener('click', function () {
      var data = {
        title: document.title,
        text: '帥氣柴柴的自介',
        url: location.href
      };
      if (navigator.share) {
        navigator.share(data).catch(function () {});
        return;
      }
      copyText(location.href).then(
        function () { toast('網址複製好了'); },
        function () { toast('複製失敗，手動複製網址吧'); }
      );
    });
  })();

  /* ── 最後更新日期：只需改 HTML 裡 datetime 那一處 ───── */
  (function () {
    var el = $('#updated');
    if (!el) return;
    var d = (el.getAttribute('datetime') || '').split('-');
    if (d.length === 3) el.textContent = d[0] + ' / ' + d[1] + ' / ' + d[2];
  })();

  /* ── 回到頂端 ───────────────────────────────────────── */
  (function () {
    var btn = $('#btn-top');
    if (!btn) return;
    btn.addEventListener('click', function () {
      window.scrollTo({ top: 0, behavior: reduce ? 'auto' : 'smooth' });
    });
  })();

})();
