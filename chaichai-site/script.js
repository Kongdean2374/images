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
     找不到 assets/chaichai.mp3 時整個播放器不會出現，
     避免訪客看到一個按不動的東西。 */
  (function () {
    var box   = $('#player');
    var audio = $('#pl-audio');
    if (!box || !audio) return;

    var playBtn = $('#pl-play'), muteBtn = $('#pl-mute');
    var seek = $('#pl-seek'), fill = $('#pl-fill');
    var timeEl = $('#pl-time'), vol = $('#pl-vol');
    var egg = $('#btn-egg');
    var ready = false;

    function fmt(sec) {
      if (!isFinite(sec) || sec < 0) sec = 0;
      var m = Math.floor(sec / 60), s2 = Math.floor(sec % 60);
      return m + ':' + (s2 < 10 ? '0' : '') + s2;
    }

    /* 音量記憶（無痕視窗可能存取失敗，包起來） */
    function store(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
    function load(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }

    var savedVol = parseFloat(load('chai.vol'));
    if (!isFinite(savedVol)) savedVol = 0.7;
    audio.volume = savedVol;
    vol.value = Math.round(savedVol * 100);

    var savedMute = load('chai.muted') === '1';
    audio.muted = savedMute;
    box.classList.toggle('is-muted', savedMute);
    if (muteBtn) muteBtn.setAttribute('aria-pressed', savedMute ? 'true' : 'false');

    /* 顯示 / 隱藏 */
    function show() {
      if (ready) return;
      ready = true;
      box.hidden = false;
      document.body.classList.add('has-player');
    }
    function hide() {
      ready = false;
      box.hidden = true;
      document.body.classList.remove('has-player');
      if (egg) egg.hidden = true;
    }

    /* 先確認音檔在不在 */
    if (location.protocol === 'file:' || !window.fetch) {
      show();   // 本機直接開檔時無法預檢，先顯示
    } else {
      fetch('assets/chaichai.mp3', { method: 'HEAD' })
        .then(function (r) { r.ok ? show() : hide(); })
        .catch(hide);
    }
    audio.addEventListener('error', hide, true);

    /* 播放 / 暫停 */
    function toggle() {
      if (audio.paused) {
        var p = audio.play();
        if (p && p.catch) p.catch(function () { toast('播不動，重新整理看看'); });
      } else {
        audio.pause();
      }
    }
    playBtn.addEventListener('click', toggle);

    audio.addEventListener('play', function () {
      box.classList.add('is-playing');
      playBtn.setAttribute('aria-label', '暫停');
    });
    audio.addEventListener('pause', function () {
      box.classList.remove('is-playing');
      playBtn.setAttribute('aria-label', '播放');
    });
    audio.addEventListener('ended', function () {
      box.classList.remove('is-playing');
      fill.style.width = '0%';
    });

    /* 進度 */
    audio.addEventListener('timeupdate', function () {
      var d = audio.duration;
      var pct = (isFinite(d) && d > 0) ? (audio.currentTime / d) * 100 : 0;
      fill.style.width = pct + '%';
      seek.setAttribute('aria-valuenow', Math.round(pct));
      timeEl.textContent = fmt(audio.currentTime);
    });
    audio.addEventListener('loadedmetadata', function () {
      timeEl.textContent = fmt(0);
    });

    function seekTo(clientX) {
      var d = audio.duration;
      if (!isFinite(d) || d <= 0) return;
      var r = seek.getBoundingClientRect();
      var ratio = Math.min(1, Math.max(0, (clientX - r.left) / r.width));
      audio.currentTime = ratio * d;
    }
    seek.addEventListener('click', function (e) { seekTo(e.clientX); });
    seek.addEventListener('keydown', function (e) {
      var d = audio.duration;
      if (!isFinite(d) || d <= 0) return;
      if (e.key === 'ArrowRight') { audio.currentTime = Math.min(d, audio.currentTime + 5); e.preventDefault(); }
      if (e.key === 'ArrowLeft')  { audio.currentTime = Math.max(0, audio.currentTime - 5); e.preventDefault(); }
    });

    /* 音量 */
    vol.addEventListener('input', function () {
      var v = vol.value / 100;
      audio.volume = v;
      store('chai.vol', v);
      if (v > 0 && audio.muted) {
        audio.muted = false;
        box.classList.remove('is-muted');
        store('chai.muted', '0');
        if (muteBtn) muteBtn.setAttribute('aria-pressed', 'false');
      }
    });

    muteBtn.addEventListener('click', function () {
      /* 手機上滑桿是收起來的，第一下先展開 */
      if (window.matchMedia('(max-width:600px)').matches && !box.classList.contains('vol-open')) {
        box.classList.add('vol-open');
        return;
      }
      audio.muted = !audio.muted;
      box.classList.toggle('is-muted', audio.muted);
      muteBtn.setAttribute('aria-pressed', audio.muted ? 'true' : 'false');
      store('chai.muted', audio.muted ? '1' : '0');
    });

    /* 點播放器以外的地方，手機的音量滑桿收回去 */
    document.addEventListener('click', function (e) {
      if (!box.contains(e.target)) box.classList.remove('vol-open');
    });

    /* 語錄區那顆 🐾 也接到同一個播放器 */
    if (egg) {
      egg.addEventListener('click', function () {
        if (box.hidden) { toast('音檔還沒放上去（assets/chaichai.mp3）'); return; }
        toggle();
        egg.classList.toggle('is-on', !audio.paused);
        if (!audio.paused) toast('汪。');
      });
    }
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
