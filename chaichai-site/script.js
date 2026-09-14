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

    var rt;
    window.addEventListener('resize', function () {
      clearTimeout(rt);
      rt = setTimeout(resize, 180);
    });
    document.addEventListener('visibilitychange', function () {
      document.hidden ? stop() : start();
    });
  })();

  /* ── 進場動畫 ───────────────────────────────────────── */
  (function () {
    var targets = $$('.sec__head, .intro, .intro__t, .traits, .talk, .lede, .tags, .save, .sub, .roster, .chart, .wall .ph, .dir__col, .quote, .quote__btns');
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
      '我不是已讀不回，我是真的在睡。',
      '剛認識的我跟熟了之後的我，建議當成兩個人看。',
      '幹話沒有關閉按鈕，這件事先講在前面。',
      '如果我突然安靜，通常是沒電，不是生氣。',
      '上午有機率還在睡，晚上才比較像正式開機。',
      '預設值不一定不好，只是它擺在那裡，看起來很欠動。',
      '講重點，我對客套話過敏。',
      '我飛得比我走過的路還遠，這句在講光遇，不是人生。',
      '認定的人我會記很久，得罪我的也是。',
      '別叫我早點睡，我對這句話已經有抗體了。'
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

  /* ── 常駐播放器 ─────────────────────────────────────
     YouTube 播放器藏在封面底下。封面設 pointer-events:none，
     所以點擊會直接落在 iframe 裡的播放鍵上 —— 對瀏覽器來說是
     「iframe 內的真實使用者操作」，iOS 才不會擋掉播放。
     要換歌就改 YT_ID（YouTube 網址 watch?v= 後面那串）。 */
  (function () {
    var YT_ID  = 'dQw4w9WgXcQ';
    var ORIGIN = 'https://www.youtube-nocookie.com';

    var box   = $('#player');
    var slot  = $('#pl-slot');
    var close = $('#pl-close');
    var egg   = $('#btn-egg');
    if (!box || !slot) return;

    var iframe = null, live = false, ping = null;

    function build() {
      iframe = document.createElement('iframe');
      iframe.id = 'pl-yt';
      iframe.title = '配著自介一起食用';
      iframe.src = ORIGIN + '/embed/' + YT_ID +
                   '?playsinline=1&rel=0&modestbranding=1&enablejsapi=1&origin=' +
                   encodeURIComponent(location.origin);
      iframe.allow = 'autoplay; encrypted-media; picture-in-picture';
      iframe.setAttribute('allowfullscreen', '');
      iframe.setAttribute('referrerpolicy', 'strict-origin-when-cross-origin');
      slot.appendChild(iframe);

      /* 跟 iframe 要播放狀態，這樣才知道什麼時候把封面收掉 */
      iframe.addEventListener('load', function () {
        var n = 0;
        clearInterval(ping);
        ping = setInterval(function () {
          if (!iframe || ++n > 12) { clearInterval(ping); return; }
          try {
            iframe.contentWindow.postMessage(
              '{"event":"listening","id":"chai","channel":"widget"}', ORIGIN);
          } catch (e) {}
        }, 500);
      });
    }

    function reveal() {
      if (live) return;
      live = true;
      clearInterval(ping);
      box.classList.add('is-live');
      if (egg) egg.classList.add('is-on');
    }

    function reset() {
      live = false;
      clearInterval(ping);
      box.classList.remove('is-live');
      slot.innerHTML = '';          // 移掉 iframe 才會真的停止播放
      iframe = null;
      if (egg) egg.classList.remove('is-on');
      build();                       // 重新備好，下次還是一點就播
    }

    /* YouTube 回報的播放狀態：1 = 播放中 */
    window.addEventListener('message', function (e) {
      if (e.origin !== ORIGIN) return;
      var d;
      try { d = typeof e.data === 'string' ? JSON.parse(e.data) : e.data; } catch (x) { return; }
      if (!d) return;
      var st = (d.event === 'onStateChange') ? d.info
             : (d.info && typeof d.info.playerState === 'number') ? d.info.playerState
             : null;
      if (st === 1) reveal();
    });

    /* 後備：使用者把焦點點進 iframe 時也視為開始播 */
    window.addEventListener('blur', function () {
      setTimeout(function () {
        if (iframe && document.activeElement === iframe) reveal();
      }, 0);
    });

    if (close) close.addEventListener('click', reset);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && live && $('#lightbox').hidden) reset();
    });

    /* 語錄區那顆 🐾：捲到播放器並提示 */
    if (egg) {
      egg.addEventListener('click', function () {
        if (live) { reset(); return; }
        box.animate
          ? box.animate([{ transform: 'translateY(0)' }, { transform: 'translateY(-6px)' },
                         { transform: 'translateY(0)' }], { duration: 420, iterations: 2 })
          : null;
        toast('左下角那塊，點一下就會播。');
      });
    }

    build();
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

  /* ── 回到頂端 ───────────────────────────────────────── */
  (function () {
    var btn = $('#btn-top');
    if (!btn) return;
    btn.addEventListener('click', function () {
      window.scrollTo({ top: 0, behavior: reduce ? 'auto' : 'smooth' });
    });
  })();

})();
