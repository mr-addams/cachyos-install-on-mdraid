# cachyos-install-on-mdraid

Установка **CachyOS + rEFInd** на программный RAID1 (`mdadm`, 2 диска) с зеркалированием ESP.
Отработано на Lenovo P510, подойдёт любому UEFI-железу с двумя дисками.

## Схема

| Раздел | Тип | Куда идёт |
|--------|-----|-----------|
| `sdX1` | `ef00`, FAT32 | ESP отдельно на каждом диске (не в RAID — UEFI не понимает mdraid) |
| `sdX2` | `fd00` | член `/dev/md0` (RAID1, **metadata=1.0**) → `/boot` (ext4) |
| `sdX3` | `fd00` | член `/dev/md1` (RAID1, metadata=1.2) → `/` (ext4) |

`/boot` обязан использовать `metadata=1.0`: суперблок в конце устройства, данные ФС
с offset 0 — иначе EFI-драйвер rEFInd увидит мусор вместо суперблока ext4.
Резервный ESP синхронизируется с основного через pacman-хук (не live-mirror,
а синхронизация по событию обновления ядра/rEFInd).

## Быстрый запуск из live-ISO

Загрузиться с CachyOS ISO (UEFI, сеть поднята), выполнить от root:

```bash
curl -fsSL https://raw.githubusercontent.com/mr-addams/cachyos-install-on-mdraid/v1.1.0/boot.sh | sudo bash
```

> ⚠️ **Скрипт разрушающий**: оба указанных диска будут полностью зачищены
> (`sgdisk --zap-all` + `wipefs`). Дважды проверьте имена дисков в интерактивном опросе.

Для тестового прогона на свежем `main` (без пина на тег):

```bash
curl -fsSL https://raw.githubusercontent.com/mr-addams/cachyos-install-on-mdraid/main/boot.sh | sudo bash
```

Переменные окружения для `boot.sh`:

| Переменная | Дефолт | Назначение |
|------------|--------|------------|
| `P510_REPO` | `mr-addams/cachyos-install-on-mdraid` | форк/зеркало репозитория |
| `P510_REF` | `main` | ветка/тег для клонирования |

## Два режима — оба по SSH

Инвариант проекта: ручная и быстрая установки одинаково запускаются через SSH,
чтобы потом автоматизировать.

**Ручной (интерактив + TUI):** нужен TTY — запускать с `ssh -t`:

```bash
ssh -t liveiso 'curl -fsSL https://raw.githubusercontent.com/mr-addams/cachyos-install-on-mdraid/v1.1.0/boot.sh | sudo bash'
```

`boot.sh` перецепляет stdin с pipe на `/dev/tty`, дальше обычный опрос + TUI фазы B.

**Быстрый (сценарий, без TTY):**

```bash
cp scenario.example.env stand.env   # заполнить: диски, пароли, CONFIRM_DESTROY=yes
chmod 600 stand.env
scp stand.env liveiso:/tmp/stand.env
ssh liveiso 'curl -fsSL https://raw.githubusercontent.com/mr-addams/cachyos-install-on-mdraid/v1.1.0/boot.sh | sudo bash -s -- --unattended --scenario /tmp/stand.env'
```

Сценарий — env-файл (пример: `scenario.example.env`). Фаза B идёт через
`archinstall --silent` с логом `/tmp/archinstall-silent.log`, весь прогон —
в `/tmp/p510-install.log`. Локаль, пользователи, sudoers, NetworkManager
донастраиваются детерминированно в фазе C (TUI-режим этот блок пропускает).
Пароли после установки затираются `shred`. Нюанс: если сборка archinstall
на ISO не знает ядро `linux-cachyos`, скрипт временно ставит ванильный `linux`,
а фаза C меняет его на запрошенное.

## Файлы

| Файл | Назначение |
|------|------------|
| `boot.sh` | bootstrap: ставит `git`/`curl` в live-ISO, клонирует репо по пину, запускает установщик |
| `install-cachyos-refind-mdraid.sh` | основной установщик: интерактив по умолчанию, `--unattended --scenario` для автоматики (фазы A–D) |
| `scenario.example.env` | шаблон сценария для unattended-режима |
| `cachyos-refind-mdraid-install.md` | ручная пошаговая инструкция (тот же процесс без автоматики) |

Процесс установщика: фаза A — разметка, mdraid, mkfs, монтирование;
фаза B — CachyOS/archinstall TUI в режиме `pre_mounted_config`;
фаза C — донастройка rEFInd/ESP + memtest86+ в chroot;
фаза D — зеркалирование второго ESP + pacman-хук синхронизации.

## Проверка отказоустойчивости (перед продом)

1. Выключить машину, физически отключить один диск.
2. Загрузиться с оставшегося (запись rEFInd своего диска в F12-меню).
3. `cat /proc/mdstat` — массивы в degraded (`[U_]`/`[_U]`), система грузится.
4. Подключить диск, `mdadm --manage /dev/md0 --add /dev/sdX2` и то же для `md1`,
   дождаться ресинка, прогнать `sync-efi-mirror.sh` вручную.

## Лицензия

MIT — см. `LICENSE`.
