#!/bin/bash
set -euo pipefail

# ==============================================================================
# Интерактивный скрипт подготовки дисков + запуск CachyOS TUI-инсталлятора
# для конфигурации rEFInd + mdraid RAID1 (2 диска)
#
# Архитектура:
#   Фаза A — подготовка дисков (разметка, mdraid, mkfs, монтирование)
#   Фаза B — запуск CachyOS TUI-инсталлятора (pre_mounted_config)
#   Фаза C — донастройка rEFInd/ESP + memtest86+ внутри chroot
#   Фаза D — зеркалирование ESP + автохук синхронизации
#
# Запуск: из live-окружения CachyOS ISO (root, сеть поднята)
# ==============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_step() {
    echo -e "\n${GREEN}==> $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

# ==============================================================================
# Шаг 0: Проверка окружения
# ==============================================================================
log_step "Шаг 0: Проверка окружения"

if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт нужно запускать от root"
    exit 1
fi

# UEFI обязателен: rEFInd + efibootmgr без efivarfs не работают.
# Почему здесь, а не позже: разметка дисков разрушающая, нет смысла
# спрашивать 10 вопросов и затирать диски, чтобы потом упасть на efibootmgr.
if [[ ! -d /sys/firmware/efi ]]; then
    log_error "Система загружена не в UEFI-режиме (/sys/firmware/efi отсутствует)."
    echo "Перезагрузитесь с ISO в UEFI-режиме (без CSM/Legacy)."
    exit 1
fi

# Все внешние зависимости скрипта — одним проходом, до опроса переменных.
REQUIRED_TOOLS=(sgdisk mdadm rsync efibootmgr arch-chroot blkid wipefs partprobe udevadm python3)
MISSING_TOOLS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done
if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    log_error "Отсутствуют зависимости: ${MISSING_TOOLS[*]}"
    echo "В live-окружении CachyOS: pacman -Sy gdisk mdadm rsync efibootmgr arch-install-scripts util-linux systemd python"
    exit 1
fi

# Сеть нужна Фазе B (инсталлятор тянет пакеты) и Фазе C (доустановка в chroot).
# Не фатально здесь: ISO мог поднять сеть позже, но предупредить надо до
# разрушающих действий, а не после разметки.
if ! getent hosts archlinux.org &> /dev/null; then
    log_warn "DNS не резолвится (getent hosts archlinux.org). Проверьте сеть перед Фазой B."
    read -rp "Сети нет. Продолжить всё равно? (yes/no) [no]: " NET_CONFIRM
    NET_CONFIRM=${NET_CONFIRM:-no}
    if [[ "$NET_CONFIRM" != "yes" ]]; then
        log_error "Остановлено: без сети установка невозможна"
        exit 1
    fi
fi

# ==============================================================================
# ФАЗА A — Подготовка дисков
# ==============================================================================

# ==============================================================================
# Шаг 1: Интерактивный опрос переменных
# ==============================================================================
log_step "Шаг 1: Опрос переменных"

echo "Доступные диски:"
lsblk -d -o NAME,SIZE,MODEL
echo

# Имена дисков
read -rp "Введите имя первого диска (например sda или nvme0n1): " DISK1
read -rp "Введите имя второго диска (например sdb или nvme1n1): " DISK2

if [[ -z "$DISK1" || -z "$DISK2" ]]; then
    log_error "Имена дисков не могут быть пустыми"
    exit 1
fi

if [[ "$DISK1" == "$DISK2" ]]; then
    log_error "Диски должны быть разными"
    exit 1
fi

if [[ ! -b "/dev/$DISK1" ]]; then
    log_error "Диск /dev/$DISK1 не существует"
    exit 1
fi

if [[ ! -b "/dev/$DISK2" ]]; then
    log_error "Диск /dev/$DISK2 не существует"
    exit 1
fi

# Размер ESP
read -rp "Размер ESP-раздела [512MiB]: " ESP_SIZE
ESP_SIZE=${ESP_SIZE:-512MiB}

# Размер /boot
read -rp "Размер раздела /boot [1GiB]: " BOOT_SIZE
BOOT_SIZE=${BOOT_SIZE:-1GiB}

# Размер / (пока не используется, весь остаток)
read -rp "Размер раздела / (пусто = весь остаток): " ROOT_SIZE
ROOT_SIZE=${ROOT_SIZE:-}

# Метки
read -rp "Метка root-тома [cachy_root]: " ROOT_LABEL
ROOT_LABEL=${ROOT_LABEL:-cachy_root}

read -rp "Метка /boot [cachy_boot]: " BOOT_LABEL
BOOT_LABEL=${BOOT_LABEL:-cachy_boot}

# Метки ext4 — макс. 16 символов, иначе mkfs обрежет молча и volume в
# refind.conf не совпадёт с реальной меткой (система не загрузится).
if [[ ! "$ROOT_LABEL" =~ ^[A-Za-z0-9_-]{1,16}$ ]]; then
    log_error "Метка root '$ROOT_LABEL': только [A-Za-z0-9_-], длина 1-16"
    exit 1
fi
if [[ ! "$BOOT_LABEL" =~ ^[A-Za-z0-9_-]{1,16}$ ]]; then
    log_error "Метка /boot '$BOOT_LABEL': только [A-Za-z0-9_-], длина 1-16"
    exit 1
fi

# Hostname
read -rp "Hostname будущей системы: " HOSTNAME
if [[ -z "$HOSTNAME" ]]; then
    log_error "Hostname не может быть пустым"
    exit 1
fi
if [[ ! "$HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
    log_error "Некорректный hostname: '$HOSTNAME'"
    exit 1
fi

# Дополнительные пакеты (справочно — archinstall TUI позволит выбрать свои)
read -rp "Доп. пакеты для заметки на память (архинсталл спросит сам, тут только справочно): " EXTRA_PKGS
EXTRA_PKGS=${EXTRA_PKGS:-}

# ==============================================================================
# Шаг 2: Формирование и отображение плана разметки
# ==============================================================================
log_step "Шаг 2: План разметки"

echo "
План разметки:
  Диск 1: /dev/$DISK1
  Диск 2: /dev/$DISK2

  Разделы на каждом диске:
    1. ESP ($ESP_SIZE, ef00, FAT32)
    2. /boot ($BOOT_SIZE, fd00, ext4, член /dev/md0, RAID1 metadata=1.0)
    3. / (весь остаток, fd00, ext4, член /dev/md1, RAID1 metadata=1.2)

  Метки:
    /boot: $BOOT_LABEL
    /:     $ROOT_LABEL

  Hostname: $HOSTNAME

  Доп. пакеты: ${EXTRA_PKGS:-нет}

  Установка: CachyOS TUI-инсталлятор (pre_mounted_config)
  После инсталлятора: донастройка rEFInd/ESP (chroot)
"

# ==============================================================================
# Шаг 3: Подтверждение перед разрушающими действиями
# ==============================================================================
log_warn "ВНИМАНИЕ: Все данные на дисках /dev/$DISK1 и /dev/$DISK2 будут УНИЧТОЖЕНЫ!"
read -rp "Продолжить? (yes/no) [no]: " CONFIRM
CONFIRM=${CONFIRM:-no}

if [[ "$CONFIRM" != "yes" ]]; then
    log_error "Установка отменена пользователем"
    exit 1
fi

# ==============================================================================
# Шаг 4: Разметка дисков
# ==============================================================================
log_step "Шаг 4: Разметка дисков"

# Формат размеров для sgdisk -n: число + единица. Проверяем до разрушения дисков.
if [[ ! "$ESP_SIZE" =~ ^[0-9]+(MiB|GiB)$ ]]; then
    log_error "Некорректный размер ESP: '$ESP_SIZE' (пример: 512MiB)"
    exit 1
fi
if [[ ! "$BOOT_SIZE" =~ ^[0-9]+(MiB|GiB)$ ]]; then
    log_error "Некорректный размер /boot: '$BOOT_SIZE' (пример: 1GiB)"
    exit 1
fi
if [[ -n "$ROOT_SIZE" && ! "$ROOT_SIZE" =~ ^[0-9]+(MiB|GiB)$ ]]; then
    log_error "Некорректный размер /: '$ROOT_SIZE' (пример: 50GiB, пусто = остаток)"
    exit 1
fi

# Стопим зависшие массивы ДО zap: иначе ядро держит разделы открытыми
# и sgdisk/wipefs получат EBUSY на занятых устройствах.
for stale_md in /dev/md0 /dev/md1; do
    if [[ -b "$stale_md" ]]; then
        log_warn "Останавливаю зависший массив $stale_md перед разметкой"
        mdadm --stop "$stale_md" || true
    fi
done

# Очистка и разметка первого диска
echo "==> Разметка /dev/$DISK1"
sgdisk --zap-all "/dev/$DISK1"
sgdisk -n1:0:+"${ESP_SIZE}" -t1:ef00 -c1:"EFI-${DISK1}" "/dev/$DISK1"
sgdisk -n2:0:+"${BOOT_SIZE}" -t2:fd00 -c2:"BOOT-${DISK1}" "/dev/$DISK1"
if [[ -n "$ROOT_SIZE" ]]; then
    sgdisk -n3:0:+"${ROOT_SIZE}" -t3:fd00 -c3:"ROOT-${DISK1}" "/dev/$DISK1"
else
    sgdisk -n3:0:0 -t3:fd00 -c3:"ROOT-${DISK1}" "/dev/$DISK1"
fi

# Очистка и разметка второго диска
echo "==> Разметка /dev/$DISK2"
sgdisk --zap-all "/dev/$DISK2"
sgdisk -n1:0:+"${ESP_SIZE}" -t1:ef00 -c1:"EFI-${DISK2}" "/dev/$DISK2"
sgdisk -n2:0:+"${BOOT_SIZE}" -t2:fd00 -c2:"BOOT-${DISK2}" "/dev/$DISK2"
if [[ -n "$ROOT_SIZE" ]]; then
    sgdisk -n3:0:+"${ROOT_SIZE}" -t3:fd00 -c3:"ROOT-${DISK2}" "/dev/$DISK2"
else
    sgdisk -n3:0:0 -t3:fd00 -c3:"ROOT-${DISK2}" "/dev/$DISK2"
fi

# Определение имён разделов (работает для sda/sdb и nvme0n1/nvme1n1)
if [[ "$DISK1" =~ [0-9]$ ]]; then
    # NVMe: nvme0n1 -> nvme0n1p1, nvme0n1p2, nvme0n1p3
    PART1_1="${DISK1}p1"
    PART1_2="${DISK1}p2"
    PART1_3="${DISK1}p3"
    PART2_1="${DISK2}p1"
    PART2_2="${DISK2}p2"
    PART2_3="${DISK2}p3"
else
    # SATA/SCSI: sda -> sda1, sda2, sda3
    PART1_1="${DISK1}1"
    PART1_2="${DISK1}2"
    PART1_3="${DISK1}3"
    PART2_1="${DISK2}1"
    PART2_2="${DISK2}2"
    PART2_3="${DISK2}3"
fi

# sgdisk --zap-all сносит GPT, но НЕ трогает md-суперблоки на разделах
# (metadata 1.0 живёт в конце устройства, 1.2 — со сдвигом 4K — оба переживают
# пересоздание таблицы). Без зачистки mdadm --create упрётся в
# "appears to be part of an array" именно на повторном прогоне скрипта.
echo "==> Зачистка сигнатур на новых разделах"
wipefs -a "/dev/$PART1_1" "/dev/$PART1_2" "/dev/$PART1_3" \
         "/dev/$PART2_1" "/dev/$PART2_2" "/dev/$PART2_3"
mdadm --zero-superblock "/dev/$PART1_2" "/dev/$PART1_3" \
                       "/dev/$PART2_2" "/dev/$PART2_3" 2>/dev/null || true

# Ядро кеширует таблицу разделов: без partprobe+settle следующий mdadm --create
# может не увидеть свежие /dev/sdX2 (гонка udev, особенно на NVMe).
partprobe "/dev/$DISK1" "/dev/$DISK2"
udevadm settle
echo "==> Таблицы разделов перечитаны — OK"

# ==============================================================================
# Шаг 5: Создание RAID-массивов
# ==============================================================================
log_step "Шаг 5: Создание RAID-массивов"

# Проверка, не существуют ли уже массивы
if [[ -b /dev/md0 ]]; then
    log_warn "Устройство /dev/md0 уже существует!"
    read -rp "Пересоздать? (yes/no) [no]: " RECREATE_MD0
    RECREATE_MD0=${RECREATE_MD0:-no}
    if [[ "$RECREATE_MD0" == "yes" ]]; then
        mdadm --stop /dev/md0 || true
    else
        log_error "Невозможно продолжить с существующим /dev/md0"
        exit 1
    fi
fi

if [[ -b /dev/md1 ]]; then
    log_warn "Устройство /dev/md1 уже существует!"
    read -rp "Пересоздать? (yes/no) [no]: " RECREATE_MD1
    RECREATE_MD1=${RECREATE_MD1:-no}
    if [[ "$RECREATE_MD1" == "yes" ]]; then
        mdadm --stop /dev/md1 || true
    else
        log_error "Невозможно продолжить с существующим /dev/md1"
        exit 1
    fi
fi

# /boot — metadata 1.0 обязательно, иначе rEFInd/UEFI не прочитает ФС напрямую
# --run: не спрашивать подтверждение, массивы нужны сразу для mkfs.
echo "==> Создание /dev/md0 (boot, metadata=1.0)"
mdadm --create /dev/md0 --run --level=1 --raid-devices=2 \
      --metadata=1.0 "/dev/$PART1_2" "/dev/$PART2_2"

# / — обычный 1.2
echo "==> Создание /dev/md1 (root, metadata=1.2)"
mdadm --create /dev/md1 --run --level=1 --raid-devices=2 \
      --metadata=1.2 "/dev/$PART1_3" "/dev/$PART2_3"

udevadm settle
for md in /dev/md0 /dev/md1; do
    if [[ ! -b "$md" ]]; then
        log_error "Массив $md не появился после --create"
        exit 1
    fi
done

echo "==> Проверка массивов:"
cat /proc/mdstat
mdadm --detail /dev/md0
mdadm --detail /dev/md1

# ==============================================================================
# Шаг 6: Создание файловых систем
# ==============================================================================
log_step "Шаг 6: Создание файловых систем"

echo "==> Создание ext4 на /dev/md0 (boot)"
mkfs.ext4 -L "$BOOT_LABEL" /dev/md0

echo "==> Создание ext4 на /dev/md1 (root)"
mkfs.ext4 -L "$ROOT_LABEL" /dev/md1

echo "==> Создание FAT32 на ESP"
mkfs.fat -F32 -n EFI_A "/dev/$PART1_1"
mkfs.fat -F32 -n EFI_B "/dev/$PART2_1"

# ==============================================================================
# Шаг 7: Монтирование
# ==============================================================================
log_step "Шаг 7: Монтирование"

mount /dev/md1 /mnt
mkdir -p /mnt/boot /mnt/boot/efi
mount /dev/md0 /mnt/boot
mount "/dev/$PART1_1" /mnt/boot/efi

# ==============================================================================
# ФАЗА B — Запуск CachyOS TUI-инсталлятора
# ==============================================================================

# ==============================================================================
# Шаг 8: Проверка наличия инсталлятора
# ==============================================================================
log_step "Шаг 8: Поиск инсталлятора"

# Порядок: нативные CachyOS-инсталляторы первыми, чистый archinstall — запасной.
# Почему только command -v без запуска --help: TUI-инсталляторы на --help могут
# открыть интерфейс вместо печати help и подвесить скрипт. Детект — только по
# наличию бинарника, никаких пробных запусков.
INSTALLER=""
for candidate in cachyos-installer cachyos-install archinstall; do
    if command -v "$candidate" &> /dev/null; then
        INSTALLER="$candidate"
        break
    fi
done

if [[ -z "$INSTALLER" ]]; then
    log_error "Инсталлятор не найден (искал: cachyos-installer, cachyos-install, archinstall)!"
    echo "Проверьте вручную:"
    echo "  which cachyos-installer cachyos-install archinstall"
    echo "  pacman -Qs cachyos-cli-installer"
    echo "Возможно, live-ISO не является CachyOS, или инсталлятор называется иначе."
    exit 1
fi

log_step "Найден инсталлятор: $INSTALLER"

# ==============================================================================
# Шаг 9: Значение bootloader для конфига (предзаполнение, не догма)
# ==============================================================================
log_step "Шаг 9: Предзаполнение bootloader"

# Сознательно НЕ детектим enum через --list-bootloaders / python-import / --help:
# флага --list-bootloaders у archinstall нет, путь Python-модуля меняется между
# версиями, а --help у TUI может подвесить скрипт. Все три способа — хрупкие.
# Конфиг ниже — только предзаполнение: инсталлятор запускается НЕ в --silent,
# пользователь видит значение в TUI и правит руками. Безопасный дефолт — Refind:
# он есть во всех версиях archinstall, а Фаза C всё равно переустановит/дополнит
# rEFInd нужными файлами. Если в TUI доступен вариант без загрузчика — выбрать его.
BOOTLOADER_VALUE="Refind"
echo "==> Предзаполнение bootloader: '$BOOTLOADER_VALUE' (проверьте в TUI вручную)"

# ==============================================================================
# Шаг 10: Генерация JSON-конфига для archinstall
# ==============================================================================
log_step "Шаг 10: Генерация JSON-конфига archinstall"

ARCHINSTALL_CONFIG="/tmp/archinstall-disk-config.json"

# Схема: актуальный ключ bootloader_config + устаревший bootloader рядом.
# Почему оба: свежий archinstall читает bootloader_config (args.py), старый —
# только bootloader (deprecated-фолбэк). Дублирование безвредно: новый приоритетно
# берёт bootloader_config, старый игнорирует неизвестный ключ.
cat > "$ARCHINSTALL_CONFIG" << CONFEOF
{
    "disk_config": {
        "config_type": "pre_mounted_config",
        "mountpoint": "/mnt"
    },
    "bootloader_config": {
        "bootloader": "$BOOTLOADER_VALUE"
    },
    "bootloader": "$BOOTLOADER_VALUE",
    "hostname": "$HOSTNAME"
}
CONFEOF

echo "==> Конфиг сохранён: $ARCHINSTALL_CONFIG"
echo "--- Содержимое ---"
cat "$ARCHINSTALL_CONFIG"
echo "--- конец ---"

# ==============================================================================
# Шаг 11: Запуск инсталлятора
# ==============================================================================
log_step "Шаг 11: Запуск CachyOS TUI-инсталлятора"

echo "Инсталлятор запустится в режиме pre_mounted_config."
echo "Разметка НЕ будет затронута — инсталлятор берёт то, что уже смонтировано под /mnt."
echo "Вы сможете интерактивно выбрать: локаль, пользователей, сеть, доп. пакеты."
echo
read -rp "Открыть инсталлятор с этим конфигом? (yes/no) [no]: " LAUNCH_CONFIRM
LAUNCH_CONFIRM=${LAUNCH_CONFIRM:-no}

if [[ "$LAUNCH_CONFIRM" != "yes" ]]; then
    log_error "Установка отменена пользователем"
    exit 1
fi

# Запуск без --silent: пользователь докручивает TUI-интерфейс.
# Нюанс: C++ TUI (cachyos-install) может не понимать --config вообще — тогда
# пробуем голый запуск, чтобы не упираться в usage-error вместо установки.
if $INSTALLER --config "$ARCHINSTALL_CONFIG"; then
    echo "==> Инсталлятор завершён успешно"
else
    INSTALLER_EXIT=$?
    log_warn "Инсталлятор завершился с кодом $INSTALLER_EXIT"
    echo "Это может быть нормально (пользователь вышел вручную), ошибкой,"
    echo "или признаком что '$INSTALLER' не понимает --config."
    read -rp "Запустить '$INSTALLER' без конфига (голый TUI)? (yes/no) [no]: " BARE_CONFIRM
    BARE_CONFIRM=${BARE_CONFIRM:-no}
    if [[ "$BARE_CONFIRM" == "yes" ]]; then
        echo "==> Голый запуск: в TUI выберите pre-mounted / существующие разделы вручную,"
        echo "    загрузчик '$BOOTLOADER_VALUE' (или без загрузчика — Фаза C донастроит rEFInd сама)."
        if $INSTALLER; then
            echo "==> Инсталлятор завершён успешно"
        else
            log_warn "Голый запуск завершился с кодом $?"
        fi
    fi
fi

# ==============================================================================
# Шаг 12: Проверка после инсталлятора
# ==============================================================================
log_step "Шаг 12: Проверка после инсталлятора"

# Проверяем что /mnt всё ещё смонтирован — по уровням, а не одним махом:
# инсталлятор может сбросить один уровень (обычно /boot/efi), а mount /dev/md1
# поверх уже смонтированного /mnt даст EBUSY. Поэтому каждый уровень — отдельно.
if ! mountpoint -q /mnt; then
    echo "==> Перемонтирую /mnt"
    mount /dev/md1 /mnt
fi
mkdir -p /mnt/boot /mnt/boot/efi
if ! mountpoint -q /mnt/boot; then
    echo "==> Перемонтирую /mnt/boot"
    mount /dev/md0 /mnt/boot
fi
if ! mountpoint -q /mnt/boot/efi; then
    log_warn "/mnt/boot/efi не смонтирован! Инсталлятор мог размонтировать разделы."
    echo "Попытка перемонтировать..."
    mount "/dev/$PART1_1" /mnt/boot/efi
    echo "==> Разделы перемонтированы"
else
    echo "==> /mnt/boot/efi смонтирован — OK"
fi

# Проверяем что в /mnt есть базовая система
if [[ ! -d /mnt/etc ]] || [[ ! -f /mnt/etc/fstab ]]; then
    log_error "В /mnt не обнаружена установка системы (/etc или fstab отсутствуют)"
    echo "Инсталлятор мог не завершить установку. Проверьте вручную."
    exit 1
fi

echo "==> Базовая система установлена — OK"

# ==============================================================================
# ФАЗА C — Донастройка rEFInd/ESP внутри chroot
# ==============================================================================

# ==============================================================================
# Шаг 13: chroot — донастройка системы
# ==============================================================================
log_step "Шаг 13: Фаза C — донастройка rEFInd/ESP + memtest86+ (chroot)"

# Копируем скрипт для chroot
cat > /mnt/tmp/chroot-setup.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail

echo "==> [Фаза C] Донастройка rEFInd/ESP"

# ------------------------------------------------------------------
# C.0: Гарантировать пакеты в таргете (TUI мог их не выбрать)
#       Без mdadm система не соберёт RAID на загрузке = unbootable.
#       --needed: не переустанавливать то что уже есть.
# ------------------------------------------------------------------
echo "==> C.0: Доустановка пакетов в таргет"
pacman -S --noconfirm --needed mdadm refind rsync efibootmgr gdisk dosfstools

# ------------------------------------------------------------------
# C.1: Перезаписать /etc/mdadm.conf (архинсталл мог написать некорректно
#       из-за "too complicated to detect" для RAID)
# ------------------------------------------------------------------
echo "==> C.1: Перезапись /etc/mdadm.conf"
mdadm --detail --scan > /etc/mdadm.conf

# ------------------------------------------------------------------
# C.2: Проверить/добавить mdadm_udev в HOOKS mkinitcpio.conf
#       Идемпотентно: grep перед sed, не задублировать при повторном запуске
# ------------------------------------------------------------------
echo "==> C.2: Проверка mdadm_udev в HOOKS"
if ! grep -q "mdadm_udev" /etc/mkinitcpio.conf; then
    sed -i 's/^HOOKS=(\(.*\)filesystems/HOOKS=(\1 mdadm_udev filesystems/' /etc/mkinitcpio.conf
    echo "    mdadm_udev добавлен в HOOKS"
else
    echo "    mdadm_udev уже есть в HOOKS — OK"
fi

# ------------------------------------------------------------------
# C.3: Пересборка initramfs
# ------------------------------------------------------------------
echo "==> C.3: mkinitcpio -P"
mkinitcpio -P

# ------------------------------------------------------------------
# C.4: Убедиться что rEFInd установлен на primary ESP
#       Если инсталлятор поставил "Refind" — просто дополняем.
#       Если "No Bootloader" — устанавливаем через refind-install.
# ------------------------------------------------------------------
echo "==> C.4: Проверка/установка rEFInd"
if [[ ! -d /boot/efi/EFI/refind ]]; then
    echo "    rEFInd не найден — устанавливаем через refind-install"
    refind-install --usedefault "ESP_DEVICE_PLACEHOLDER"
else
    echo "    rEFInd уже установлен — дополняем конфиг"
fi

# ------------------------------------------------------------------
# C.5: Установка ext4-драйвера для rEFInd
#       rEFInd должен читать ext4 /boot через EFI-драйвер,
#       т.к. /boot на mdraid RAID1, не на ESP
# ------------------------------------------------------------------
echo "==> C.5: Установка ext4-драйвера"
mkdir -p /boot/efi/EFI/refind/drivers_x64
EXT4_DRIVER=$(pacman -Ql refind | grep ext4_x64.efi | awk '{print $2}')
if [[ -n "$EXT4_DRIVER" ]]; then
    cp "$EXT4_DRIVER" /boot/efi/EFI/refind/drivers_x64/
    echo "    ext4_x64.efi скопирован"
else
    echo "    ОШИБКА: ext4_x64.efi не найден в пакете refind!"
    echo "    Проверьте: pacman -Ql refind | grep drivers_x64"
    exit 1
fi

# ------------------------------------------------------------------
# C.6: Установка memtest86+ (EFI) и размещение на ESP
#       rEFInd не грузит .iso-файлы напрямую (нет loopback-драйвера),
#       поэтому вместо ISO используем .efi-бинарь memtest86+ —
#       стандартный, поддерживаемый rEFInd сценарий:
#       путь EFI/tools/ обнаруживается автоматически (≥0.7.3.6),
#       стансь в refind.conf не нужна.
# ------------------------------------------------------------------
echo "==> C.6: Установка memtest86+ (EFI)"
if pacman -S --noconfirm memtest86+-efi; then
    # Определяем фактический путь .efi-бинаря (структура каталогов меняется между версиями)
    MEMTEST_EFI=$(pacman -Ql memtest86+-efi | awk '{print $2}' | grep -E '\.efi$' | head -n1)
    if [[ -n "$MEMTEST_EFI" ]]; then
        mkdir -p /boot/efi/EFI/tools
        cp "$MEMTEST_EFI" /boot/efi/EFI/tools/memtest86.efi
        echo "    memtest86+ скопирован в /boot/efi/EFI/tools/memtest86.efi"
    else
        echo "    ОШИБКА: .efi-бинарь не найден в пакете memtest86+-efi"
        echo "    Проверьте: pacman -Ql memtest86+-efi | grep .efi"
    fi
else
    echo "    ОШИБКА: не удалось установить memtest86+-efi"
    echo "    Проверьте подключение к интернету и репозитории"
fi

# ------------------------------------------------------------------
# C.7: Генерация refind.conf со стансой CachyOS
#       volume — метка /boot (BOOT_LABEL), rEFInd видит её как UEFI-том
#       благодаря ext4-драйверу, независимо от того, что это mdraid
# ------------------------------------------------------------------
echo "==> C.7: Генерация /boot/efi/EFI/refind/refind.conf"
ROOT_UUID=$(blkid -s UUID -o value /dev/md1)
cat > /boot/efi/EFI/refind/refind.conf << REFIND_CONF_EOF
menuentry "CachyOS" {
    icon     /EFI/refind/icons/os_arch.png
    volume   "BOOT_LABEL_PLACEHOLDER"
    loader   /vmlinuz-linux-cachyos
    initrd   /initramfs-linux-cachyos.img
    options  "root=UUID=${ROOT_UUID} rw quiet splash"
}
REFIND_CONF_EOF

# ------------------------------------------------------------------
# C.8: Проверка + автофикс /etc/fstab
#       archinstall честно предупреждает: RAID "too complicated to detect",
#       поэтому для pre-mounted md-массивов записей может не быть вообще.
#       Правило: mountpoint отсутствует → дописать по UUID (бэкап .bak);
#       mountpoint есть, но через /dev-путь → оставить, только предупредить
#       (грузится и так, UUID стабильнее, но молча переписывать чужое не будем).
# ------------------------------------------------------------------
echo "==> C.8: Проверка /etc/fstab"
cp -a /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"

ensure_fstab_entry() {
    local dev="$1" mountpoint="$2" fstype="$3" opts="$4" dump_pass="$5"
    local uuid
    uuid=$(blkid -s UUID -o value "$dev")
    if [[ -z "$uuid" ]]; then
        echo "    ОШИБКА: не могу прочитать UUID $dev"
        return 1
    fi
    if grep -Eq "[[:space:]]${mountpoint}[[:space:]]" /etc/fstab; then
        if grep -E "[[:space:]]${mountpoint}[[:space:]]" /etc/fstab | grep -q "UUID=$uuid"; then
            echo "    $mountpoint (UUID=$uuid) — OK"
        else
            echo "    ВНИМАНИЕ: $mountpoint есть в fstab, но не по UUID=$uuid — оставляю как есть:"
            grep -E "[[:space:]]${mountpoint}[[:space:]]" /etc/fstab | sed 's/^/      /'
        fi
    else
        echo "UUID=$uuid  $mountpoint  $fstype  $opts  $dump_pass" >> /etc/fstab
        echo "    $mountpoint отсутствовал — дописан по UUID=$uuid"
    fi
}

ensure_fstab_entry /dev/md1 / ext4 "rw,relatime" "0 1"
ensure_fstab_entry /dev/md0 /boot ext4 "rw,relatime" "0 2"
ensure_fstab_entry ESP_DEVICE_PLACEHOLDER /boot/efi vfat "rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro" "0 2"

echo "    Итоговый fstab:"
cat /etc/fstab | sed 's/^/      /'

echo "==> [Фаза C] Донастройка завершена"
CHROOT_EOF

chmod +x /mnt/tmp/chroot-setup.sh

# Подстановка переменных в chroot-скрипт
sed -i "s|ESP_DEVICE_PLACEHOLDER|/dev/$PART1_1|g" /mnt/tmp/chroot-setup.sh
sed -i "s|BOOT_LABEL_PLACEHOLDER|$BOOT_LABEL|g" /mnt/tmp/chroot-setup.sh

# Выполнение chroot-скрипта
echo "==> Запуск настройки в chroot"
arch-chroot /mnt /bin/bash /tmp/chroot-setup.sh

# ==============================================================================
# ФАЗА D — Зеркалирование ESP + автохук
# ==============================================================================

# ==============================================================================
# Шаг 14: Второй ESP — начальная копия + вторая NVRAM-запись
# ==============================================================================
log_step "Шаг 14: Фаза D — настройка второго ESP"

echo "==> Монтирование второго ESP"
mkdir -p /mnt/efi_b
mount "/dev/$PART2_1" /mnt/efi_b

echo "==> Синхронизация ESP (primary → backup)"
rsync -a --delete /mnt/boot/efi/ /mnt/efi_b/

echo "==> Размонтирование второго ESP"
umount /mnt/efi_b
rmdir /mnt/efi_b

echo "==> Создание NVRAM-записи для второго ESP"
arch-chroot /mnt efibootmgr --create --disk "/dev/$DISK2" --part 1 \
    --label "rEFInd (backup)" \
    --loader '\EFI\BOOT\BOOTX64.EFI'

# ==============================================================================
# Шаг 15: Установка pacman-хука синхронизации ESP
# ==============================================================================
log_step "Шаг 15: Установка pacman-хука синхронизации ESP"

# Создание каталога для хуков
mkdir -p /mnt/etc/pacman.d/hooks

# Создание хука
cat > /mnt/etc/pacman.d/hooks/95-refind-sync-efi.hook << HOOK_EOF
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = linux-cachyos
Target = refind
Target = mkinitcpio
Target = memtest86+-efi

[Action]
Description = Sync primary ESP -> backup ESP disk
When = PostTransaction
Exec = /usr/local/bin/sync-efi-mirror.sh
HOOK_EOF

# Создание скрипта синхронизации.
# Привязка по PARTUUID, а не /dev/sdX: буквы дисков плавают при перестановке
# SATA-портов и добавлении NVMe, PARTUUID записан в GPT и стабилен.
mkdir -p /mnt/usr/local/bin

BACKUP_PARTUUID=$(blkid -s PARTUUID -o value "/dev/$PART2_1")
if [[ -n "$BACKUP_PARTUUID" ]]; then
    BACKUP_SRC="/dev/disk/by-partuuid/$BACKUP_PARTUUID"
    echo "==> Backup ESP: $BACKUP_SRC (PARTUUID=$BACKUP_PARTUUID)"
else
    log_warn "PARTUUID для /dev/$PART2_1 не читается — откат на прямой путь"
    BACKUP_SRC="/dev/$PART2_1"
fi

cat > /mnt/usr/local/bin/sync-efi-mirror.sh << SYNC_SCRIPT_EOF
#!/bin/bash
set -euo pipefail

PRIMARY_ESP=/boot/efi
BACKUP_SRC=$BACKUP_SRC
MOUNT_POINT=/run/efi-backup-sync

# Робастный cleanup: umount/rmdir с || true — если mount не удался,
# trap на EXIT не должен ронять pacman-хук ложной ошибкой.
cleanup() {
    umount "\$MOUNT_POINT" 2>/dev/null || true
    rmdir "\$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -d "\$PRIMARY_ESP" ]]; then
    echo "sync-efi-mirror: \$PRIMARY_ESP отсутствует" >&2
    exit 1
fi
if [[ ! -b "\$BACKUP_SRC" ]]; then
    echo "sync-efi-mirror: источник \$BACKUP_SRC не блочное устройство" >&2
    exit 1
fi

mkdir -p "\$MOUNT_POINT"
mount "\$BACKUP_SRC" "\$MOUNT_POINT"

rsync -a --delete "\$PRIMARY_ESP"/ "\$MOUNT_POINT"/
SYNC_SCRIPT_EOF

chmod +x /mnt/usr/local/bin/sync-efi-mirror.sh

# ==============================================================================
# Финал
# ==============================================================================
log_step "Завершение установки"

echo "==> Размонтирование всех разделов"
umount -R /mnt

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Установка завершена!                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo "Для завершения:"
echo "  1. Извлеките установочный носитель"
echo "  2. Перезагрузитесь (reboot)"
echo "  3. В UEFI Boot Menu (F12) выберите запись rEFInd"
echo
echo "Для проверки отказоустойчивости:"
echo "  - Отключите один диск, загрузитесь с другого"
echo "  - Убедитесь, что RAID-массивы поднялись в degraded-режиме"
echo "  - Подключите диск обратно и восстановите:"
echo "      mdadm --manage /dev/md0 --add /dev/${DISK1}2"
echo "      mdadm --manage /dev/md1 --add /dev/${DISK1}3"
echo
echo -e "${YELLOW}НЕ перезагружайтесь автоматически — извлеките носитель вручную!${NC}"
