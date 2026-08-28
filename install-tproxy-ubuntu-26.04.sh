#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
TPROXY_COMMIT="52a5feb7fac38f68da5afef9cedd9b3bfc8473ca"
REPOSITORY="/opt/tproxy-server"
SECRET_FILE="/root/tproxy-web-secret"
CONNECTION_FILE="/root/tproxy-connection.txt"
SITE_STAGE=""
PATCHED_REPOSITORY=0

DOMAIN=""
ACME_EMAIL=""
SSH_PORT="22"
PROVIDED_SECRET=""

usage() {
    cat <<'USAGE'
Usage:
  sudo ./install-tproxy-ubuntu-26.04.sh \
    --domain proxy.example.com \
    --email admin@example.com \
    [--ssh-port 22] \
    [--secret 32-lowercase-hex]

If --domain or --email is omitted, the script asks interactively.
Omit --secret to generate it securely on the server.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

show_diagnostics() {
    local exit_code=$?
    trap - ERR
    echo
    echo "Installation failed (exit ${exit_code}). Diagnostics:"
    systemctl --no-pager --full status \
        caddy mtproxy tproxy-server tproxy-firewall fail2ban 2>/dev/null || true
    journalctl -u mtproxy -u tproxy-server -u caddy -n 60 --no-pager 2>/dev/null || true
    exit "${exit_code}"
}

cleanup() {
    if [[ "${PATCHED_REPOSITORY}" == "1" && -d "${REPOSITORY}/.git" ]]; then
        git -C "${REPOSITORY}" restore \
            deploy/install.sh deploy/install-mtproxy.sh 2>/dev/null || true
    fi
    if [[ "${SITE_STAGE}" == /tmp/iron-form-site.* && -d "${SITE_STAGE}" ]]; then
        rm -rf "${SITE_STAGE}"
    fi
}
trap cleanup EXIT
trap show_diagnostics ERR

while (($#)); do
    case "$1" in
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --email) ACME_EMAIL="${2:-}"; shift 2 ;;
        --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
        --secret) PROVIDED_SECRET="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown argument: $1" ;;
    esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root."
[[ "$(uname -m)" == "x86_64" ]] || die "Ubuntu x86_64 is required."
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]] ||
    die "This installer is intended for Ubuntu 26.04 LTS."

if [[ -z "${DOMAIN}" ]]; then
    read -r -p "Domain (example: proxy.example.com): " DOMAIN
fi
DOMAIN="${DOMAIN,,}"
if [[ -z "${ACME_EMAIL}" ]]; then
    read -r -p "ACME email: " ACME_EMAIL
fi

[[ "${DOMAIN}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "${DOMAIN}" == *.* ]] ||
    die "Domain must be a lowercase ASCII hostname."
[[ "${ACME_EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
    die "Invalid ACME email."
[[ "${SSH_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] && ((SSH_PORT <= 65535)) ||
    die "Invalid SSH port."
if [[ -n "${PROVIDED_SECRET}" ]]; then
    [[ "${PROVIDED_SECRET}" =~ ^[0-9a-f]{32}$ ]] ||
        die "Secret must contain exactly 32 lowercase hexadecimal characters."
fi

for target in \
    "${REPOSITORY}" /opt/MTProxy /srv/tproxy-site \
    /etc/tproxy-server /etc/caddy /usr/local/bin/tproxy-server \
    /etc/fail2ban/fail2ban.local \
    /etc/fail2ban/jail.d/sshd-local.conf
do
    [[ ! -e "${target}" ]] || die "Existing installation path found: ${target}"
done

for port in 80 443 2398 8080 8081 8888; do
    if ss -H -lnt | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
        die "Port ${port} is already in use."
    fi
done

echo "[1/9] Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git openssl dnsutils ufw fail2ban

mapfile -t DNS_IPS < <(dig +short A "${DOMAIN}" | sort -u)
((${#DNS_IPS[@]} > 0)) || die "No IPv4 A record found for ${DOMAIN}."
PUBLIC_IP="$(curl -4fsS --max-time 15 https://api.ipify.org)"
printf '%s\n' "${DNS_IPS[@]}" | grep -Fxq "${PUBLIC_IP}" ||
    die "DNS for ${DOMAIN} does not include this server IP (${PUBLIC_IP})."
if dig +short AAAA "${DOMAIN}" | grep -q .; then
    echo "WARNING: ${DOMAIN} has an AAAA record. Confirm that IPv6 reaches this VPS."
fi

echo "[2/9] Configuring UFW..."
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow 80/tcp comment 'HTTP ACME'
ufw allow 443/tcp comment 'HTTPS WEB proxy'
ufw --force enable

echo "[3/9] Creating the IRON FORM public site..."
SITE_STAGE="$(mktemp -d /tmp/iron-form-site.XXXXXX)"
cat > "${SITE_STAGE}/index.html" <<'__IRON_FORM_INDEX__'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="IRON FORM — понятные тренировки, питание и восстановление для сильного, здорового тела.">
  <meta name="theme-color" content="#0b0d0c">
  <title>IRON FORM — фитнес и бодибилдинг без лишнего шума</title>
  <link rel="stylesheet" href="styles.css">
  <script src="script.js" defer></script>
</head>
<body>
  <a class="skip-link" href="#main">К содержанию</a>
  <header class="site-header">
    <nav class="container nav" aria-label="Главная навигация">
      <a class="brand" href="index.html"><span class="brand-mark">IF</span> IRON FORM</a>
      <button class="menu-button" data-menu-button aria-expanded="false" aria-label="Открыть меню">Меню</button>
      <div class="nav-links" data-menu>
        <a href="index.html" aria-current="page">Главная</a>
        <a href="programs.html">Программы</a>
        <a href="nutrition.html">Питание</a>
        <a href="about.html">О проекте</a>
      </div>
    </nav>
  </header>

  <main id="main">
    <section class="hero">
      <div class="container hero-grid">
        <div>
          <p class="eyebrow">Сила · форма · система</p>
          <h1>Строй тело, которое работает.</h1>
          <p class="lead">Практичный фитнес без магии: базовые движения, разумная прогрессия, питание и восстановление.</p>
          <div class="hero-actions">
            <a class="button" href="programs.html">Выбрать программу</a>
            <a class="button secondary" href="nutrition.html">Рассчитать питание</a>
          </div>
        </div>
        <div class="hero-panel" aria-label="Декоративная иллюстрация штанги">
          <div class="weight"></div>
          <div class="panel-copy"><span class="panel-number">3×</span><p>тренировки в неделю — достаточная база для устойчивого прогресса новичка.</p></div>
        </div>
      </div>
    </section>

    <section class="section alt">
      <div class="container">
        <div class="section-head"><div><p class="eyebrow">Основа результата</p><h2>Три элемента прогресса</h2></div><p>Сильная программа не обязана быть сложной. Она должна быть выполнимой, измеримой и достаточно гибкой для обычной жизни.</p></div>
        <div class="grid-3">
          <article class="card"><span class="card-number">01</span><h3>Тренировки</h3><p>Освойте технику, записывайте подходы и постепенно увеличивайте нагрузку.</p><span class="tag">База</span><span class="tag">Прогрессия</span></article>
          <article class="card"><span class="card-number">02</span><h3>Питание</h3><p>Держите подходящую калорийность и получайте достаточно белка из привычных продуктов.</p><span class="tag">Баланс</span><span class="tag">Белок</span></article>
          <article class="card"><span class="card-number">03</span><h3>Восстановление</h3><p>Сон, дни отдыха и управление нагрузкой помогают тренироваться стабильно месяцами.</p><span class="tag">Сон</span><span class="tag">Отдых</span></article>
        </div>
      </div>
    </section>

    <section class="section">
      <div class="container">
        <div class="stats">
          <div class="stat"><strong>3</strong><span>готовые программы</span></div>
          <div class="stat"><strong>45–70</strong><span>минут на тренировку</span></div>
          <div class="stat"><strong>2–3</strong><span>минуты отдыха в базе</span></div>
          <div class="stat"><strong>7–9</strong><span>часов сна — ориентир</span></div>
        </div>
      </div>
    </section>

    <section class="section">
      <div class="container cta">
        <p class="eyebrow" style="color:#34400f">Начните спокойно</p>
        <h2>Первые восемь недель важнее идеального плана.</h2>
        <p>Выберите простой режим, оставляйте 1–3 повтора в запасе и отслеживайте технику, самочувствие и рабочие веса.</p>
        <a class="button" href="programs.html">Открыть программы</a>
      </div>
    </section>
  </main>

  <footer class="site-footer"><div class="container footer-grid"><div><a class="brand" href="index.html"><span class="brand-mark">IF</span> IRON FORM</a><p class="small">Образовательный проект о силовом тренинге.</p></div><div class="footer-links"><a href="programs.html">Программы</a><a href="nutrition.html">Питание</a><a href="about.html">О проекте</a></div></div><div class="container small">© <span data-year></span> IRON FORM</div></footer>
</body>
</html>
__IRON_FORM_INDEX__
cat > "${SITE_STAGE}/programs.html" <<'__IRON_FORM_PROGRAMS__'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="Три программы силовых тренировок: старт, масса и верх-низ.">
  <meta name="theme-color" content="#0b0d0c"><title>Программы тренировок — IRON FORM</title>
  <link rel="stylesheet" href="styles.css"><script src="script.js" defer></script>
</head>
<body>
  <a class="skip-link" href="#main">К содержанию</a>
  <header class="site-header"><nav class="container nav" aria-label="Главная навигация"><a class="brand" href="index.html"><span class="brand-mark">IF</span> IRON FORM</a><button class="menu-button" data-menu-button aria-expanded="false" aria-label="Открыть меню">Меню</button><div class="nav-links" data-menu><a href="index.html">Главная</a><a href="programs.html" aria-current="page">Программы</a><a href="nutrition.html">Питание</a><a href="about.html">О проекте</a></div></nav></header>
  <main id="main">
    <section class="page-hero"><div class="container"><p class="eyebrow">Тренировочный план</p><h1>Выберите объём, который сможете поддерживать.</h1><p class="lead">Начинайте с небольших весов. Перед рабочими подходами выполняйте разминку, а при боли прекращайте упражнение.</p></div></section>
    <section class="section"><div class="container">
      <article class="program"><div class="program-top"><div><h2>Старт: всё тело</h2><p class="muted">Для новичков. Чередуйте тренировки A и B три раза в неделю, оставляя день отдыха.</p></div><span class="program-badge">3 дня/нед.</span></div>
        <table class="exercise-table"><thead><tr><th>Упражнение</th><th>Подходы × повторы</th><th>Примечание</th></tr></thead><tbody><tr><td>Присед со штангой или гоблет-присед</td><td>3 × 6–10</td><td>Контроль глубины</td></tr><tr><td>Жим лёжа или отжимания</td><td>3 × 6–12</td><td>Лопатки стабильны</td></tr><tr><td>Тяга горизонтального блока</td><td>3 × 8–12</td><td>Без рывков</td></tr><tr><td>Румынская тяга</td><td>2 × 8–10</td><td>Нейтральная спина</td></tr><tr><td>Планка</td><td>3 × 30–60 сек.</td><td>Ровное дыхание</td></tr></tbody></table>
      </article>
      <article class="program"><div class="program-top"><div><h2>Верх / низ</h2><p class="muted">Четыре занятия для продолжающих: два дня верха и два дня низа.</p></div><span class="program-badge">4 дня/нед.</span></div>
        <table class="exercise-table"><thead><tr><th>День</th><th>Основные движения</th><th>Объём</th></tr></thead><tbody><tr><td>Верх A</td><td>Жим лёжа, тяга блока, жим гантелей, подтягивания</td><td>3–4 × 6–12</td></tr><tr><td>Низ A</td><td>Присед, румынская тяга, выпады, икры</td><td>3–4 × 6–15</td></tr><tr><td>Верх B</td><td>Жим стоя, тяга штанги, жим гантелей, руки</td><td>3–4 × 8–15</td></tr><tr><td>Низ B</td><td>Тяга, жим ногами, сгибание ног, корпус</td><td>2–4 × 5–15</td></tr></tbody></table>
      </article>
      <article class="program"><div class="program-top"><div><h2>Домашняя база</h2><p class="muted">Минимум оборудования: турник, резинка и пара разборных гантелей.</p></div><span class="program-badge">3 дня/нед.</span></div>
        <table class="exercise-table"><thead><tr><th>Упражнение</th><th>Подходы × повторы</th><th>Усложнение</th></tr></thead><tbody><tr><td>Болгарские выпады</td><td>3 × 8–15</td><td>Добавляйте вес</td></tr><tr><td>Отжимания</td><td>4 × 6–20</td><td>Ноги на опоре</td></tr><tr><td>Подтягивания / тяга резинки</td><td>4 × 5–15</td><td>Медленный негатив</td></tr><tr><td>Ягодичный мост</td><td>3 × 10–20</td><td>Одна нога</td></tr><tr><td>Боковая планка</td><td>3 × 20–45 сек.</td><td>Поднять верхнюю ногу</td></tr></tbody></table>
      </article>
      <div class="notice"><strong>Правило прогрессии:</strong> когда выполнены все подходы в верхней границе повторов с хорошей техникой, увеличьте вес на 2–5%. Не тренируйтесь через острую боль.</div>
    </div></section>
  </main>
  <footer class="site-footer"><div class="container footer-grid"><div><a class="brand" href="index.html"><span class="brand-mark">IF</span> IRON FORM</a><p class="small">Образовательный проект о силовом тренинге.</p></div><div class="footer-links"><a href="programs.html">Программы</a><a href="nutrition.html">Питание</a><a href="about.html">О проекте</a></div></div><div class="container small">© <span data-year></span> IRON FORM</div></footer>
</body></html>
__IRON_FORM_PROGRAMS__
cat > "${SITE_STAGE}/nutrition.html" <<'__IRON_FORM_NUTRITION__'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="Базовые принципы питания для набора мышц, поддержания формы и снижения веса.">
  <meta name="theme-color" content="#0b0d0c"><title>Питание и калькулятор — IRON FORM</title>
  <link rel="stylesheet" href="styles.css"><script src="script.js" defer></script>
</head>
<body>
  <a class="skip-link" href="#main">К содержанию</a>
  <header class="site-header"><nav class="container nav" aria-label="Главная навигация"><a class="brand" href="index.html"><span class="brand-mark">IF</span> IRON FORM</a><button class="menu-button" data-menu-button aria-expanded="false" aria-label="Открыть меню">Меню</button><div class="nav-links" data-menu><a href="index.html">Главная</a><a href="programs.html">Программы</a><a href="nutrition.html" aria-current="page">Питание</a><a href="about.html">О проекте</a></div></nav></header>
  <main id="main">
    <section class="page-hero"><div class="container"><p class="eyebrow">Энергия и восстановление</p><h1>Питание, которое можно соблюдать.</h1><p class="lead">Сначала калорийность и белок, затем детали. Рацион должен подходить вашему бюджету, расписанию и самочувствию.</p></div></section>
    <section class="section"><div class="container split">
      <div><p class="eyebrow">Короткий чек-лист</p><h2>Соберите основу</h2><ul class="checklist"><li>Белок в 3–5 приёмах пищи в течение дня.</li><li>Овощи, фрукты и цельные продукты ежедневно.</li><li>Углеводы вокруг тренировок для энергии.</li><li>Достаточно воды; ориентируйтесь на жажду и условия.</li><li>Изменяйте калорийность постепенно, а не резко.</li></ul><div class="notice">При заболеваниях, беременности, расстройствах пищевого поведения или назначенной диете обсудите рацион с врачом или квалифицированным диетологом.</div></div>
      <form class="calculator" data-calculator><p class="eyebrow">Ориентировочный расчёт</p><h3>Суточная калорийность</h3><div class="field-grid"><label>Пол<select name="sex"><option value="male">Мужской</option><option value="female">Женский</option></select></label><label>Возраст<input name="age" type="number" min="16" max="90" required placeholder="30"></label><label>Вес, кг<input name="weight" type="number" min="35" max="300" step="0.1" required placeholder="80"></label><label>Рост, см<input name="height" type="number" min="130" max="230" required placeholder="180"></label><label>Активность<select name="activity"><option value="1.2">Низкая</option><option value="1.375">1–3 тренировки</option><option value="1.55" selected>3–5 тренировок</option><option value="1.725">Высокая</option></select></label><label>Цель<select name="goal"><option value="-300">Снижение веса</option><option value="0" selected>Поддержание</option><option value="250">Набор массы</option></select></label></div><button class="button" type="submit" style="margin-top:20px">Рассчитать</button><div class="result" data-result aria-live="polite">Введите данные — результат появится здесь.</div><p class="small muted">Расчёт по формуле Миффлина — Сан Жеора является стартовой оценкой, а не медицинской рекомендацией.</p></form>
    </div></section>
    <section class="section alt"><div class="container"><div class="section-head"><div><p class="eyebrow">Практика</p><h2>Простой конструктор тарелки</h2></div><p>Размер порций меняйте под цель и фактическую динамику веса.</p></div><div class="grid-3"><article class="card"><span class="card-number">½</span><h3>Овощи и зелень</h3><p>Разнообразные свежие или приготовленные овощи как источник клетчатки.</p></article><article class="card"><span class="card-number">¼</span><h3>Источник белка</h3><p>Мясо, рыба, яйца, молочные продукты, бобовые или тофу.</p></article><article class="card"><span class="card-number">¼</span><h3>Углеводы</h3><p>Крупы, картофель, хлеб, паста или другие привычные продукты.</p></article></div></div></section>
  </main>
  <footer class="site-footer"><div class="container footer-grid"><div><a class="brand" href="index.html"><span class="brand-mark">IF</span> IRON FORM</a><p class="small">Образовательный проект о силовом тренинге.</p></div><div class="footer-links"><a href="programs.html">Программы</a><a href="nutrition.html">Питание</a><a href="about.html">О проекте</a></div></div><div class="container small">© <span data-year></span> IRON FORM</div></footer>
</body></html>
__IRON_FORM_NUTRITION__
cat > "${SITE_STAGE}/about.html" <<'__IRON_FORM_ABOUT__'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="О проекте IRON FORM и принципах безопасного силового тренинга.">
  <meta name="theme-color" content="#0b0d0c"><title>О проекте — IRON FORM</title>
  <link rel="stylesheet" href="styles.css"><script src="script.js" defer></script>
</head>
<body>
  <a class="skip-link" href="#main">К содержанию</a>
  <header class="site-header"><nav class="container nav" aria-label="Главная навигация"><a class="brand" href="index.html"><span class="brand-mark">IF</span> IRON FORM</a><button class="menu-button" data-menu-button aria-expanded="false" aria-label="Открыть меню">Меню</button><div class="nav-links" data-menu><a href="index.html">Главная</a><a href="programs.html">Программы</a><a href="nutrition.html">Питание</a><a href="about.html" aria-current="page">О проекте</a></div></nav></header>
  <main id="main">
    <section class="page-hero"><div class="container"><p class="eyebrow">О проекте</p><h1>Сильнее — значит устойчивее.</h1><p class="lead">IRON FORM помогает организовать тренировки без экстремальных обещаний, стыда и культа идеальной формы.</p></div></section>
    <section class="section"><div class="container split"><div><h2>Наши принципы</h2><ul class="checklist"><li>Техника и регулярность важнее рекордов любой ценой.</li><li>Программа должна соответствовать опыту и доступному времени.</li><li>Питание не делится на «чистое» и «запрещённое».</li><li>Прогресс оценивается по силе, самочувствию и устойчивым привычкам.</li></ul></div><div class="card"><p class="eyebrow">Связаться</p><h3>Вопросы и предложения</h3><p>Замените адрес ниже на собственный перед публикацией сайта.</p><p><a class="button secondary" href="mailto:hello@example.com">hello@example.com</a></p><p class="small muted">Мы не продаём персональные планы и не собираем данные посетителей через формы.</p></div></div></section>
    <section class="section alt"><div class="container"><h2>Важное ограничение</h2><div class="notice">Материалы сайта предназначены только для общего ознакомления. Они не заменяют диагностику, лечение и персональные рекомендации врача, физиотерапевта или квалифицированного тренера. При травме, боли или хроническом заболевании получите профессиональную консультацию до начала программы.</div></div></section>
  </main>
  <footer class="site-footer"><div class="container footer-grid"><div><a class="brand" href="index.html"><span class="brand-mark">IF</span> IRON FORM</a><p class="small">Образовательный проект о силовом тренинге.</p></div><div class="footer-links"><a href="programs.html">Программы</a><a href="nutrition.html">Питание</a><a href="about.html">О проекте</a></div></div><div class="container small">© <span data-year></span> IRON FORM</div></footer>
</body></html>
__IRON_FORM_ABOUT__
cat > "${SITE_STAGE}/404.html" <<'__IRON_FORM_404__'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="robots" content="noindex"><meta name="theme-color" content="#0b0d0c">
  <title>Страница не найдена — IRON FORM</title>
  <link rel="stylesheet" href="styles.css"><script src="script.js" defer></script>
</head>
<body>
  <header class="site-header"><nav class="container nav" aria-label="Главная навигация"><a class="brand" href="index.html"><span class="brand-mark">IF</span> IRON FORM</a><div class="nav-links" style="display:flex"><a href="index.html">На главную</a></div></nav></header>
  <main class="hero"><div class="container"><p class="eyebrow">Ошибка 404</p><h1>Такой страницы нет.</h1><p class="lead">Возможно, ссылка устарела. Вернитесь на главную или откройте программы тренировок.</p><div class="hero-actions"><a class="button" href="index.html">На главную</a><a class="button secondary" href="programs.html">Программы</a></div></div></main>
  <footer class="site-footer"><div class="container small">© <span data-year></span> IRON FORM</div></footer>
</body></html>
__IRON_FORM_404__
cat > "${SITE_STAGE}/styles.css" <<'__IRON_FORM_CSS__'
:root {
  --bg: #0b0d0c;
  --surface: #141714;
  --surface-soft: #1b1f1b;
  --text: #f4f6ef;
  --muted: #a9b0a4;
  --accent: #c7ff36;
  --accent-dark: #93c900;
  --line: #2a3029;
  --danger: #ff7b57;
  --radius: 22px;
  --shadow: 0 24px 70px rgba(0, 0, 0, 0.28);
}

* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  color: var(--text);
  background:
    radial-gradient(circle at 85% 10%, rgba(199, 255, 54, 0.09), transparent 25rem),
    var(--bg);
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  line-height: 1.6;
}

a { color: inherit; text-decoration: none; }
button, input, select { font: inherit; }
.container { width: min(1120px, calc(100% - 40px)); margin-inline: auto; }
.skip-link { position: absolute; left: -999px; }
.skip-link:focus { left: 16px; top: 16px; z-index: 20; padding: 10px 14px; background: var(--accent); color: #10130c; }

.site-header {
  position: sticky;
  top: 0;
  z-index: 10;
  border-bottom: 1px solid rgba(255,255,255,.07);
  background: rgba(11, 13, 12, .88);
  backdrop-filter: blur(18px);
}
.nav { min-height: 76px; display: flex; align-items: center; justify-content: space-between; gap: 24px; }
.brand { display: inline-flex; align-items: center; gap: 11px; font-weight: 900; letter-spacing: .05em; }
.brand-mark { display: grid; place-items: center; width: 38px; height: 38px; border-radius: 12px; color: #11150a; background: var(--accent); transform: rotate(-5deg); }
.nav-links { display: flex; align-items: center; gap: 28px; color: var(--muted); font-size: 14px; font-weight: 700; }
.nav-links a:hover, .nav-links a[aria-current="page"] { color: var(--accent); }
.menu-button { display: none; border: 1px solid var(--line); border-radius: 12px; padding: 8px 11px; color: var(--text); background: var(--surface); }

.hero { padding: 92px 0 64px; }
.hero-grid { display: grid; grid-template-columns: 1.25fr .75fr; align-items: center; gap: 64px; }
.eyebrow { margin: 0 0 18px; color: var(--accent); font-size: 13px; font-weight: 900; letter-spacing: .16em; text-transform: uppercase; }
h1, h2, h3 { margin-top: 0; line-height: 1.08; }
h1 { margin-bottom: 24px; font-size: clamp(46px, 8vw, 88px); letter-spacing: -.06em; }
h2 { margin-bottom: 18px; font-size: clamp(32px, 5vw, 54px); letter-spacing: -.045em; }
h3 { margin-bottom: 10px; font-size: 22px; }
.lead { max-width: 700px; color: var(--muted); font-size: clamp(18px, 2vw, 21px); }
.hero-actions { display: flex; flex-wrap: wrap; gap: 14px; margin-top: 32px; }
.button { display: inline-flex; justify-content: center; align-items: center; min-height: 48px; padding: 0 22px; border: 1px solid var(--accent); border-radius: 999px; color: #10130c; background: var(--accent); font-weight: 850; }
.button:hover { background: #dcff83; }
.button.secondary { color: var(--text); border-color: var(--line); background: transparent; }
.button.secondary:hover { border-color: var(--accent); color: var(--accent); }

.hero-panel { position: relative; min-height: 460px; padding: 30px; overflow: hidden; border: 1px solid var(--line); border-radius: 36px; background: linear-gradient(150deg, #1c221a, #111310); box-shadow: var(--shadow); }
.hero-panel::before { content: ""; position: absolute; inset: 8% -35% auto auto; width: 360px; height: 360px; border: 70px solid rgba(199,255,54,.13); border-radius: 50%; }
.weight { position: absolute; right: 18%; bottom: 28%; width: 180px; height: 36px; border-radius: 20px; background: var(--accent); transform: rotate(-12deg); box-shadow: 0 0 55px rgba(199,255,54,.18); }
.weight::before, .weight::after { content: ""; position: absolute; top: -34px; width: 45px; height: 104px; border: 10px solid #efffc2; border-radius: 12px; }
.weight::before { left: -24px; }.weight::after { right: -24px; }
.panel-copy { position: absolute; left: 30px; right: 30px; bottom: 28px; }
.panel-number { display: block; color: var(--accent); font-size: 64px; font-weight: 950; line-height: 1; }
.panel-copy p { margin: 8px 0 0; color: var(--muted); }

.section { padding: 80px 0; }
.section.alt { background: #101310; border-block: 1px solid rgba(255,255,255,.05); }
.section-head { display: flex; justify-content: space-between; align-items: end; gap: 30px; margin-bottom: 36px; }
.section-head p { max-width: 560px; margin: 0; color: var(--muted); }
.grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; }
.card { padding: 26px; border: 1px solid var(--line); border-radius: var(--radius); background: var(--surface); }
.card:hover { border-color: #485440; transform: translateY(-2px); transition: .2s ease; }
.card-number { color: var(--accent); font-weight: 900; letter-spacing: .08em; }
.card p, .muted { color: var(--muted); }
.tag { display: inline-flex; margin: 0 6px 8px 0; padding: 6px 10px; border: 1px solid #3b4635; border-radius: 999px; color: #d8e7cf; font-size: 12px; font-weight: 750; }
.stats { display: grid; grid-template-columns: repeat(4, 1fr); border: 1px solid var(--line); border-radius: var(--radius); overflow: hidden; }
.stat { padding: 28px; background: var(--surface); border-right: 1px solid var(--line); }
.stat:last-child { border: 0; }.stat strong { display: block; color: var(--accent); font-size: 32px; }.stat span { color: var(--muted); font-size: 14px; }

.page-hero { padding: 76px 0 44px; border-bottom: 1px solid var(--line); }
.page-hero h1 { max-width: 900px; font-size: clamp(42px, 7vw, 72px); }
.program { margin-bottom: 22px; padding: 30px; border: 1px solid var(--line); border-radius: var(--radius); background: var(--surface); }
.program-top { display: flex; justify-content: space-between; gap: 24px; }
.program-badge { flex: 0 0 auto; color: var(--accent); font-weight: 900; }
.exercise-table { width: 100%; margin-top: 22px; border-collapse: collapse; }
.exercise-table th, .exercise-table td { padding: 13px 12px; border-bottom: 1px solid var(--line); text-align: left; }
.exercise-table th { color: var(--muted); font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }

.split { display: grid; grid-template-columns: 1fr 1fr; gap: 30px; }
.checklist { padding: 0; list-style: none; }
.checklist li { position: relative; margin: 12px 0; padding-left: 30px; color: var(--muted); }
.checklist li::before { content: "✓"; position: absolute; left: 0; color: var(--accent); font-weight: 900; }
.calculator { padding: 30px; border: 1px solid var(--line); border-radius: var(--radius); background: var(--surface); }
.field-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
label { display: grid; gap: 7px; color: var(--muted); font-size: 13px; font-weight: 700; }
input, select { width: 100%; min-height: 46px; padding: 0 13px; border: 1px solid var(--line); border-radius: 11px; color: var(--text); background: #0d100d; }
input:focus, select:focus { outline: 2px solid var(--accent); outline-offset: 2px; }
.result { min-height: 74px; margin-top: 20px; padding: 17px; border-radius: 14px; color: #11150a; background: var(--accent); }
.notice { padding: 20px 22px; border-left: 4px solid var(--danger); background: rgba(255,123,87,.08); color: #ffd8cd; }

.cta { padding: 42px; border-radius: 30px; color: #10130c; background: var(--accent); }
.cta p { max-width: 680px; color: #34400f; }.cta .button { border-color: #10130c; color: var(--text); background: #10130c; }
.site-footer { padding: 48px 0; border-top: 1px solid var(--line); color: var(--muted); }
.footer-grid { display: grid; grid-template-columns: 1fr auto; gap: 28px; align-items: start; }
.footer-links { display: flex; flex-wrap: wrap; gap: 20px; }
.small { font-size: 13px; }

@media (max-width: 820px) {
  .hero-grid, .split { grid-template-columns: 1fr; }
  .hero-panel { min-height: 340px; }
  .grid-3 { grid-template-columns: 1fr; }
  .stats { grid-template-columns: 1fr 1fr; }.stat:nth-child(2) { border-right: 0; }.stat:nth-child(-n+2) { border-bottom: 1px solid var(--line); }
  .nav-links { display: none; position: absolute; top: 68px; left: 20px; right: 20px; padding: 20px; flex-direction: column; align-items: flex-start; border: 1px solid var(--line); border-radius: 16px; background: #111411; box-shadow: var(--shadow); }
  .nav-links.open { display: flex; }.menu-button { display: block; }
  .section-head, .program-top { align-items: start; flex-direction: column; }
}

@media (max-width: 520px) {
  .container { width: min(100% - 28px, 1120px); }
  .hero { padding-top: 62px; }.section { padding: 60px 0; }
  .stats, .field-grid { grid-template-columns: 1fr; }.stat { border-right: 0; border-bottom: 1px solid var(--line); }
  .exercise-table { font-size: 13px; }.exercise-table th, .exercise-table td { padding: 10px 7px; }
  .cta { padding: 28px; }.footer-grid { grid-template-columns: 1fr; }
}
__IRON_FORM_CSS__
cat > "${SITE_STAGE}/script.js" <<'__IRON_FORM_JS__'
const menuButton = document.querySelector('[data-menu-button]');
const menu = document.querySelector('[data-menu]');

if (menuButton && menu) {
  menuButton.addEventListener('click', () => {
    const open = menu.classList.toggle('open');
    menuButton.setAttribute('aria-expanded', String(open));
  });
}

document.querySelectorAll('[data-year]').forEach((node) => {
  node.textContent = new Date().getFullYear();
});

const form = document.querySelector('[data-calculator]');
const result = document.querySelector('[data-result]');

if (form && result) {
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const sex = data.get('sex');
    const weight = Number(data.get('weight'));
    const height = Number(data.get('height'));
    const age = Number(data.get('age'));
    const activity = Number(data.get('activity'));
    const goal = Number(data.get('goal'));

    if (!weight || !height || !age || weight < 35 || height < 130 || age < 16) {
      result.textContent = 'Проверьте введённые значения.';
      return;
    }

    const base = 10 * weight + 6.25 * height - 5 * age + (sex === 'male' ? 5 : -161);
    const calories = Math.round(base * activity + goal);
    const proteinMin = Math.round(weight * 1.6);
    const proteinMax = Math.round(weight * 2.2);
    result.innerHTML = `<strong>Ориентир: ${calories} ккал/день</strong><br><span>Белок: ${proteinMin}–${proteinMax} г. Корректируйте по динамике веса в течение 2–3 недель.</span>`;
  });
}
__IRON_FORM_JS__
find "${SITE_STAGE}" -type d -exec chmod 0755 {} +
find "${SITE_STAGE}" -type f -exec chmod 0644 {} +

echo "[4/9] Downloading pinned upstream source..."
git clone https://github.com/telegramdesktop/tproxy-server.git "${REPOSITORY}"
git -C "${REPOSITORY}" checkout --detach "${TPROXY_COMMIT}"
test "$(git -C "${REPOSITORY}" rev-parse HEAD)" = "${TPROXY_COMMIT}"

echo "[5/9] Applying Ubuntu 26.04 build-test compatibility fixes..."
INSTALLER="${REPOSITORY}/deploy/install.sh"
MTPROXY_INSTALLER="${REPOSITORY}/deploy/install-mtproxy.sh"
sed -i \
    's|(cd "$repository" && "$go_binary" test ./...)|(cd "$repository" \&\& (umask 0022; "$go_binary" test ./...))|' \
    "${INSTALLER}"
sed -i \
    's|runuser -u mtproxy -- make -C "$build_directory" -j"$(nproc)"|(umask 0022; runuser -u mtproxy -- make -C "$build_directory" -j"$(nproc)")|' \
    "${MTPROXY_INSTALLER}"
grep -Fq '(umask 0022; "$go_binary" test ./...)' "${INSTALLER}"
grep -Fq '(umask 0022; runuser -u mtproxy -- make' "${MTPROXY_INSTALLER}"
PATCHED_REPOSITORY=1

if [[ -n "${PROVIDED_SECRET}" ]]; then
    SECRET="${PROVIDED_SECRET}"
else
    SECRET="$(openssl rand -hex 16)"
fi
printf '%s\n' "${SECRET}" > "${SECRET_FILE}"
chmod 0600 "${SECRET_FILE}"

echo "[6/9] Installing Caddy, MTProxy and tproxy-server..."
"${INSTALLER}" \
    --hostname "${DOMAIN}" \
    --email "${ACME_EMAIL}" \
    --site-dir "${SITE_STAGE}" \
    < "${SECRET_FILE}"

git -C "${REPOSITORY}" restore deploy/install.sh deploy/install-mtproxy.sh
PATCHED_REPOSITORY=0
git -C "${REPOSITORY}" diff --exit-code

chmod 0755 /opt/MTProxy/objs /opt/MTProxy/objs/bin
chmod 0755 /opt/MTProxy/objs/bin/mtproto-proxy
find /srv/tproxy-site -type d -exec chmod 0755 {} +
find /srv/tproxy-site -type f -exec chmod 0644 {} +
systemctl reset-failed mtproxy tproxy-server
systemctl restart mtproxy
systemctl restart tproxy-server

echo "[7/9] Configuring Fail2ban..."
cat > /etc/fail2ban/jail.d/sshd-local.conf <<EOF
[sshd]
enabled = true
backend = systemd
filter = sshd
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 90h
banaction = ufw
ignoreip = 127.0.0.1/8 ::1
EOF
cat > /etc/fail2ban/fail2ban.local <<'EOF'
[Definition]
dbpurgeage = 604800
EOF
chown root:root \
    /etc/fail2ban/jail.d/sshd-local.conf \
    /etc/fail2ban/fail2ban.local
chmod 0644 \
    /etc/fail2ban/jail.d/sshd-local.conf \
    /etc/fail2ban/fail2ban.local
fail2ban-client -t
systemctl enable --now fail2ban
systemctl restart fail2ban
sleep 2

fail2ban-client set sshd banip 192.0.2.123 >/dev/null
ufw status | grep -Fq '192.0.2.123'
fail2ban-client set sshd unbanip 192.0.2.123 >/dev/null
! ufw status | grep -Fq '192.0.2.123'

echo "[8/9] Saving connection details..."
cat > "${CONNECTION_FILE}" <<EOF
Hostname: ${DOMAIN}
Secret: ${SECRET}
Link: tg://webproxy?server=${DOMAIN}&secret=${SECRET}
HTTPS link: https://t.me/webproxy?server=${DOMAIN}&secret=${SECRET}
EOF
chmod 0600 "${CONNECTION_FILE}"
unset SECRET PROVIDED_SECRET

echo "[9/9] Running final checks..."
for unit in caddy mtproxy tproxy-server tproxy-firewall fail2ban; do
    systemctl is-active --quiet "${unit}" || die "${unit} is not active."
    systemctl is-enabled --quiet "${unit}" || die "${unit} is not enabled."
done
systemctl is-enabled --quiet refresh-mtproxy-config.timer ||
    die "refresh-mtproxy-config.timer is not enabled."
curl --fail --silent http://127.0.0.1:8081/healthz | grep -Fxq ok
curl --fail --silent http://127.0.0.1:8081/readyz | grep -Fxq ready
nft list table inet tproxy_backend |
    grep -Fq 'tcp dport { 2398, 8888 } drop'

HTTPS_READY=0
for _ in $(seq 1 60); do
    if curl --fail --silent --location "https://${DOMAIN}/" |
        grep -Fq 'IRON FORM'; then
        HTTPS_READY=1
        break
    fi
    sleep 2
done
[[ "${HTTPS_READY}" == "1" ]] || die "HTTPS/site check failed."

[[ "$(fail2ban-client get sshd maxretry)" == "5" ]]
[[ "$(fail2ban-client get sshd findtime)" == "600" ]]
[[ "$(fail2ban-client get sshd bantime)" == "324000" ]]

echo
echo "============================================================"
echo "INSTALLATION COMPLETE"
echo "Site: https://${DOMAIN}/"
echo "Connection details: ${CONNECTION_FILE}"
echo "Fail2ban: 5 attempts / 10 minutes / 90-hour ban"
echo
echo "Show connection details:"
echo "  sudo cat ${CONNECTION_FILE}"
echo
echo "External ports that must be closed: 2398, 8888, 8080, 8081"
echo "============================================================"
