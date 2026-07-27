# FastCloud

Самохостящееся облако на базе **Nextcloud** — одной командой.
Разворачивает продакшн-стек **Nextcloud + PostgreSQL + Redis + Caddy** в Docker
за несколько минут: автоматический SSL, фаервол, защита от брутфорса, бэкапы,
Telegram-уведомления и мониторинг. Полностью бесплатно и с открытым исходным кодом.

---

## Быстрый старт

На чистом сервере Ubuntu/Debian под root:

```bash
curl -fsSL https://raw.githubusercontent.com/LMECIS/FastCloud/main/install.sh | sudo bash
```

Или скачайте и запустите вручную:

```bash
git clone https://github.com/LMECIS/FastCloud.git
cd FastCloud
sudo ./install.sh
```

Установщик спросит режим:

| Режим | Протокол | Когда использовать |
|-------|----------|--------------------|
| 1. Локальный | HTTP | домашняя сеть / VPN / тесты |
| 2. Публичный с доменом | HTTPS (Let's Encrypt) | продакшн, **рекомендуется** |
| 3. Публичный без домена | HTTP | быстрый доступ по IP (небезопасно) |

По завершении выводятся URL, логин `admin` и сгенерированный пароль.

### Требования

- Ubuntu или Debian, root-доступ
- Рекомендуется ≥ 2 ГБ RAM и ≥ 10 ГБ свободного диска
- Свободные порты 80 и 443 (nginx/apache будут остановлены автоматически)

Всё остальное (Docker, Docker Compose, fail2ban) установщик поставит сам.

---

## Управление: `manage.sh`

Стек ставится в `/opt/fastcloud`. Менеджер без аргументов открывает меню:

```bash
cd /opt/fastcloud && ./manage.sh
```

Прямые команды (удобно для cron/скриптов):

| Команда | Действие |
|---------|----------|
| `status` | статус контейнеров и диска |
| `logs [сервис]` | логи (всех или одного сервиса) |
| `start` / `stop` / `restart` | управление стеком |
| `backup` | локальный бэкап (данные + консистентный дамп БД) |
| `restore <файл>` | восстановление из бэкапа |
| `update` | обновление образов (с бэкапом перед этим) |
| `occ <аргументы>` | выполнить любую команду Nextcloud `occ` |
| `show-password` | показать пароль администратора |
| `reset-password` | сбросить пароль администратора |
| `set-domain <домен>` | добавить домен в trusted_domains и overwrite-настройки |
| `uninstall` | удалить FastCloud |
| `telegram-setup` / `telegram-test` | Telegram-уведомления |
| `monitor-setup` | мониторинг контейнеров и диска с алертами |
| `backup-setup` / `backup-remote` | оффсайт-бэкапы (S3 / B2 / Yandex через rclone) |

---

## Что внутри

- **Nextcloud** (`stable-apache`) — само облако
- **PostgreSQL 15** — база данных
- **Redis 7** — кэш и блокировки
- **Caddy 2** — reverse proxy с автоматическим HTTPS (Let's Encrypt)

Дополнительно установщик настраивает:

- UFW (открыты только 22/80/443)
- fail2ban (бан на 1 час после 5 неудачных входов) — в публичных режимах
- ротацию логов Docker и отключение IPv6
- оптимизацию Nextcloud (индексы БД, кэш Redis/APCu, системный cron)

Структура установки в `/opt/fastcloud`:

```
docker-compose.yml   manage.sh   Caddyfile   nextcloud.ini
.env                 data/       db/         redis/
scripts/telegram-report.sh   scripts/monitor.sh   scripts/backup-remote.sh
```

---

## Бэкапы

Локальный бэкап (`./manage.sh backup`) включает режим обслуживания, делает
консистентный `pg_dump` и упаковывает данные + конфиги в
`/opt/fastcloud-backups/`. Восстановление — `./manage.sh restore <файл>`.

Для оффсайт-бэкапов настройте rclone (`./manage.sh backup-setup`) — поддерживаются
S3, Backblaze B2, Yandex Disk и другие бэкенды rclone. Выгрузка ставится в cron
автоматически.

Старые архивы удаляются автоматически: локально и в облаке хранятся последние
`7` бэкапов (можно изменить переменной `FASTCLOUD_KEEP_BACKUPS`).

> Бэкапы содержат `.env` с паролями — храните их в защищённом месте.

---

## Вклад

PR и issue приветствуются. Проект распространяется под лицензией
[MIT](LICENSE).
