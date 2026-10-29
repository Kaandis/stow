(() => {
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const store = {
    get(key) { try { return localStorage.getItem(key); } catch { return null; } },
    set(key, value) { try { localStorage.setItem(key, value); } catch { /* private mode */ } },
  };

  // English lives in the HTML (what search engines index); Turkish is applied on top.
  const TR = {
    'nav.free': 'Ücretsiz',
    'nav.how': 'Nasıl çalışır',
    'nav.faq': 'SSS',
    'hero.line1': 'Daha sakin bir menü çubuğu,',
    'hero.line2': 'tek tık uzağında.',
    'hero.lead': 'Stow, nadiren kullandığın menü çubuğu simgelerini kaldırır, istediğinde geri getirir. İzin istemez, arka planda hiçbir şey çalıştırmaz.',
    'hero.download': 'Ücretsiz indir',
    'hero.github': 'GitHub’da yıldızla',
    'mb.file': 'Dosya', 'mb.edit': 'Düzen', 'mb.view': 'Görüntü', 'mb.go': 'Git', 'mb.window': 'Pencere',
    'note.t': 'Dene',
    'note.d': 'Menü çubuğundaki oka tıkla. Ayracın solundaki simgeler kaldırılır; geri getirmek için yeniden tıkla.',
    'demo.hint': 'Gerçekten çalışıyor: sağ üstteki oka tıkla. Alttaki Dock’ta yalnızca Harbor uygulamaları var; her simge kendi sitesine götürür.',
    'how.title': 'Gözden uzak, tek tık yakın.',
    'f1.t': '⌘ ile sürükleyerek seç', 'f1.d': '⌘’ye basılı tutup simgeleri Stow’un ince ayracının soluna sürükle; macOS’in simgeleri zaten taşıdığı yol bu. Sırayı macOS hatırlar, bir şeyi iki kez ayarlaman gerekmez.',
    'f2.t': 'Gizli ve Hep Gizli', 'f2.d': 'Gizli simgeler için oka tıkla; daha uzakta tuttukların için ⌥ ile tıkla. Bir süre sonra kendiliğinden geri kaldırılırlar.',
    'f3.t': 'Kısayol ya da üzerine gelmek', 'f3.d': '⌃⌥S ya da ⌥⌘B ile aç-kapat, ya da işaretçi menü çubuğunda durunca görünsünler.',
    'f4.t': 'Hafif, az şey ister', 'f4.d': 'Stow yalnızca menü çubuğunun herkese açık arayüzünü kullanır ve sen tıklayana kadar boşta bekler. İsteğe bağlı tek bir izin, macOS 27’de gizlemeyi daha akıcı yapar.',
    'cta.title': 'Ücretsiz. Sakin. Senin.',
    'cta.lead': 'Hesap yok, takip yok, izin yok.',
    'cta.note': 'macOS 15 veya üstü. Zip’i aç, Stow’u Uygulamalar’a taşı; ilk seferde sağ tıklayıp Aç’ı seç.',
    'faq.title': 'Sorular',
    'q1.q': 'Hangi simgelerin gizleneceğini nasıl seçerim?', 'q1.a': 'Menü çubuğunda ⌘’ye basılı tutup bir simgeyi sürükle. Stow’un ince ayracının solundaki her şey kaldırılır; okunun sağındakiler kalır. Sırayı macOS hatırlar.',
    'q2.q': 'macOS 27’de çalışıyor mu?', 'q2.a': 'Evet. macOS 27 menü çubuğunu tek parça çizer ve simgelerin kenarına kendi taşma okunu ekler. Stow’un kaldırdığı simgeler oraya gider; yani sistemin okundan da bir tık uzaktadırlar.',
    'q3.q': 'Neden Ice’taki gibi gizli simgeler için ayrı bir çubuk yok?', 'q3.a': 'macOS 27’de menü çubuğu simgeleri artık tek tek erişilebilir değil; ayrı bir çubuk, güncellemelerle bozulan kırılgan hilelere dayanırdı. Stow, macOS’in desteklediği yolda kalır.',
    'q4.q': 'Stow hangi izinleri istiyor?', 'q4.a': 'Çalışmak için hiçbirini. macOS 27’de Erişilebilirliğe izin verirsen Stow uygulama menülerinin nerede bittiğini görür: gizli simgeler kaymak yerine soluklaşarak kaybolur ve geri gelir, Hep Gizli de kendini boyutlandırabilir. Başka hiçbir şey okumaz.',
    'q5.q': 'macOS açılamıyor diyor.', 'q5.a': 'Sürümler henüz notarize edilmedi. Stow’a sağ tıklayıp Aç’ı seç ya da şunu çalıştır: <code>xattr -dr com.apple.quarantine /Applications/Stow.app</code>',
    'footer.license': 'MIT Lisansı',
    'footer.disclaimer': 'Stow bağımsız bir projedir; Apple Inc. ile bağlantılı değildir, Apple tarafından onaylanmamış veya desteklenmemiştir. Mac ve macOS, Apple Inc.’in ABD’de ve diğer ülkelerde tescilli ticari markalarıdır.',
  };

  const nodes = $$('[data-i18n]');
  const EN = Object.fromEntries(nodes.map((n) => [n.dataset.i18n, n.innerHTML]));
  const langButton = $('#lang');
  let lang = 'en';

  function setLanguage(next) {
    lang = next;
    nodes.forEach((n) => { n.innerHTML = (next === 'tr' ? TR : EN)[n.dataset.i18n] ?? EN[n.dataset.i18n]; });
    document.documentElement.lang = next;
    langButton.textContent = next === 'tr' ? 'EN' : 'TR';
    langButton.setAttribute('aria-label', next === 'tr' ? 'Switch to English' : 'Türkçeye geç');
    store.set('lang', next);
    tickClock();
    labelArrow();
  }

  // The Mac is built at 960×600 and scaled to fit.
  const frame = $('#macFrame');
  const mac = $('#mac');
  let k = 1;
  function fit() {
    const pad = parseFloat(getComputedStyle(frame).paddingLeft);
    k = (frame.clientWidth - pad * 2) / 960;
    mac.style.transform = `scale(${k})`;
    frame.style.height = `${600 * k + pad * 2}px`;
  }
  addEventListener('resize', fit);
  fit();

  const nav = $('#nav');
  const onScroll = () => nav.classList.toggle('scrolled', scrollY > 8);
  addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  function tickClock() {
    const now = new Date();
    const locale = lang === 'tr' ? 'tr-TR' : 'en-US';
    $('#menuClock').textContent = `${now.toLocaleDateString(locale, { weekday: 'short' })} ${now.toLocaleTimeString(locale, { hour: 'numeric', minute: '2-digit' })}`;
  }
  setInterval(tickClock, 10_000);

  // The menu bar demo: the arrow tucks away everything left of the divider,
  // and they come back on their own after a while, as in the app.
  const tuck = $('#tuck');
  const arrow = $('#sbArrow');
  let tucked = false;
  let rehide;
  function labelArrow() {
    const show = lang === 'tr' ? 'Gizli simgeleri göster' : 'Show hidden icons';
    const hide = lang === 'tr' ? 'Simgeleri gizle' : 'Hide icons';
    arrow.setAttribute('aria-label', tucked ? show : hide);
  }
  function setTucked(next) {
    tucked = next;
    mac.classList.toggle('tucked', tucked);
    arrow.setAttribute('aria-pressed', String(!tucked));
    labelArrow();
    clearTimeout(rehide);
    if (!tucked) rehide = setTimeout(() => setTucked(true), 8000);
  }
  arrow.addEventListener('click', () => {
    setTucked(!tucked);
    $('#noteCard').classList.add('done');
  });
  // Start tucked after a moment, so the first thing you see is the effect.
  setTimeout(() => setTucked(true), reduceMotion.matches ? 0 : 900);

  // The Harbor Dock: only Harbor apps, each linking to its site.
  const HARBOR = [
    { name: 'Inlet', url: 'https://kaandis.github.io/inlet/', icon: 'assets/inlet-icon.png?v=1' },
    { name: 'Ferry', url: 'https://kaandis.github.io/ferry/', icon: 'assets/ferry-icon.png?v=1' },
    { name: 'Stow', url: 'https://kaandis.github.io/stow/', icon: 'assets/icon.png?v=1', running: true, self: true },
    { name: 'Harbor', url: 'https://kaandis.github.io/harbor/', icon: 'assets/harbor-icon.png?v=1' },
  ];
  const dock = $('#dock');
  const label = $('#dockLabel');
  dock.innerHTML = HARBOR.map((app) => `<a href="${app.url}" class="${app.running ? 'running' : ''}" aria-label="${app.name}"${app.self ? ' data-self' : ' target="_blank" rel="noopener"'}><img src="${app.icon}" alt="" width="52" height="52"></a>`).join('');
  $$('a', dock).forEach((a) => {
    a.addEventListener('pointerenter', () => {
      const box = a.getBoundingClientRect();
      const macBox = mac.getBoundingClientRect();
      label.textContent = a.getAttribute('aria-label');
      label.hidden = false;
      label.style.left = `${(box.left + box.width / 2 - macBox.left) / k}px`;
    });
    a.addEventListener('pointerleave', () => { label.hidden = true; });
    if (a.hasAttribute('data-self')) {
      a.addEventListener('click', (e) => {
        e.preventDefault();
        scrollTo({ top: 0, behavior: reduceMotion.matches ? 'auto' : 'smooth' });
      });
    }
  });

  const saved = store.get('lang');
  const initial = (saved === 'tr' || saved === 'en') ? saved : ((navigator.language || '').toLowerCase().startsWith('tr') ? 'tr' : 'en');
  setLanguage(initial);
  langButton.addEventListener('click', () => setLanguage(lang === 'tr' ? 'en' : 'tr'));
})();
