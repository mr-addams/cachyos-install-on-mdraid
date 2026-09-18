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
curl -fsSL https://raw.githubusercontent.com/mr-addams/cachyos-install-on-mdraid/v1.0.0/boot.sh | sudo bash
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

## Файлы

| Файл | Назначение |
|------|------------|
| `boot.sh` | bootstrap: ставит `git`/`curl` в live-ISO, клонирует репо по пину, запускает установщик |
| `install-cachyos-refind-mdraid.sh` | основной интерактивный установщик (фазы A–D) |
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
