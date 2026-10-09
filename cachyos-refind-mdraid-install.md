# CachyOS + rEFInd на mdraid с зеркалированием EFI (Lenovo P510, 2 диска)

Схема: `/boot` — на mdadm RAID1 (ext4, metadata=1.0), `/` — на отдельном mdadm RAID1 (ext4),
ESP — отдельная FAT32-партиция на **каждом** физическом диске (не в RAID, UEFI-прошивка не понимает mdraid),
резервный ESP синхронизируется с основного автоматически через pacman-хук.

## Схема разделов (на каждом из двух дисков)

| Раздел | Тип   | Куда идёт |
|--------|-------|-----------|
| `sdX1` | ef00, FAT32 | ESP отдельно на каждом диске, не в RAID |
| `sdX2` | fd00 | член `/dev/md0` (RAID1) → `/boot` |
| `sdX3` | fd00 | член `/dev/md1` (RAID1) → `/` |

**Ключевой момент:** `/boot` на RAID1 обязан использовать `--metadata=1.0`, а не дефолтные `1.2`.
При metadata 1.0 суперблок mdadm лежит в конце устройства — данные ФС начинаются с offset 0,
точно как на обычном разделе. Это нужно, чтобы EFI-драйвер rEFInd (не знающий о существовании
mdadm) мог прочитать ext4 `/boot` напрямую с одного физического члена зеркала. При metadata 1.2
суперблок в начале сдвигает данные ФС, и любой не-md-aware ридер (rEFInd, firmware) увидит там
мусор вместо суперблока ext4.

Root (`/`) — обычный ext4 на `/dev/md1`, metadata 1.2 (ограничений нет, читает его только Linux
через mdraid-драйвер после старта initramfs).

## 0. Подготовка

Загрузиться с живого CachyOS ISO, сеть поднята. UEFI-прошивка P510 — чистый UEFI без CSM/Legacy.

```bash
lsblk -d -o NAME,SIZE,MODEL
```

Дальше `/dev/sda` и `/dev/sdb` — подставить реальные имена (может быть `nvme0n1`/`nvme1n1`).

## 1. Разметка дисков

```bash
for d in sda sdb; do
  sgdisk --zap-all /dev/$d
  sgdisk -n1:0:+512MiB -t1:ef00 -c1:"EFI-$d"   /dev/$d
  sgdisk -n2:0:+1GiB   -t2:fd00 -c2:"BOOT-$d"  /dev/$d
  sgdisk -n3:0:0       -t3:fd00 -c3:"ROOT-$d"  /dev/$d
done
```

## 2. Создание массивов

```bash
# /boot — metadata 1.0 обязательно, иначе rEFInd/UEFI не прочитает ФС напрямую
mdadm --create /dev/md0 --level=1 --raid-devices=2 \
      --metadata=1.0 /dev/sda2 /dev/sdb2

# / — обычный 1.2
mdadm --create /dev/md1 --level=1 --raid-devices=2 \
      --metadata=1.2 /dev/sda3 /dev/sdb3
```

Проверка:
```bash
cat /proc/mdstat
mdadm --detail /dev/md0
mdadm --detail /dev/md1
```

## 3. Файловые системы

```bash
mkfs.ext4 -L cachy_boot /dev/md0      # /boot
mkfs.ext4 -L cachy_root /dev/md1      # /

mount /dev/md1 /mnt
mkdir -p /mnt/boot /mnt/boot/efi
mount /dev/md0 /mnt/boot

mkfs.fat -F32 -n EFI_A /dev/sda1
mkfs.fat -F32 -n EFI_B /dev/sdb1
mount /dev/sda1 /mnt/boot/efi        # только основной ESP монтируется в систему
```

## 4. Установка базовой системы

```bash
pacstrap /mnt base base-devel linux-cachyos linux-cachyos-headers \
    mdadm efibootmgr refind vim networkmanager rsync
genfstab -U /mnt >> /mnt/etc/fstab
```

Проверить `/mnt/etc/fstab` — три строки: `/` (UUID md1), `/boot` (UUID md0), `/boot/efi` (UUID sda1).

## 5. chroot: mdadm + initramfs

```bash
arch-chroot /mnt
{ echo "HOMEHOST <ignore>"; mdadm --detail --scan; } > /etc/mdadm.conf
```

`HOMEHOST <ignore>` обязателен первой строкой: массивы созданы в live-окружении с его hostname,
а в initramfs и установленной системе hostname другой. Без этой строки udev считает массивы чужими,
root по UUID не находится и загрузка падает в emergency shell.

`/etc/mkinitcpio.conf` — добавить `mdadm_udev` перед `filesystems`:
```
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block mdadm_udev filesystems fsck)
```
```bash
mkinitcpio -P
```

## 6. rEFInd + ext4-драйвер под /boot

```bash
refind-install --usedefault /dev/sda1
```

`/boot` не на ESP, а на отдельном ext4/RAID1 — rEFInd должен читать его через встроенный EFI-драйвер ext4:

`--usedefault` кладёт rEFInd в `EFI/BOOT/` (fallback-путь прошивки, NVRAM не меняется), поэтому
конфиг и драйверы — в `EFI/BOOT/`, а не в `EFI/refind/`:

```bash
mkdir -p /boot/efi/EFI/BOOT/drivers_x64
cp /usr/share/refind/drivers_x64/ext4_x64.efi \
   /boot/efi/EFI/BOOT/drivers_x64/
```
(путь пакета может отличаться — проверить `pacman -Ql refind | grep drivers_x64`).

`/boot/efi/EFI/BOOT/refind.conf` — стансь с явным путём на volume `/boot`:

```
menuentry "CachyOS" {
    icon     /EFI/BOOT/icons/os_arch.png
    volume   "cachy_boot"
    loader   /vmlinuz-linux-cachyos
    initrd   /initramfs-linux-cachyos.img
    options  "root=UUID=<UUID-md1> rw quiet splash"
}
```

`volume "cachy_boot"` — метка раздела `/boot` (задана `-L cachy_boot` на шаге 3), rEFInd видит
её как отдельный UEFI-том благодаря ext4-драйверу, независимо от того, что это mdraid.

UUID root-массива:
```bash
blkid /dev/md1
```

## 7. Второй ESP — начальная копия + вторая NVRAM-запись

```bash
exit   # из chroot
mkdir -p /mnt/efi_b
mount /dev/sdb1 /mnt/efi_b
rsync -a --delete /mnt/boot/efi/ /mnt/efi_b/
umount /mnt/efi_b
```

```bash
arch-chroot /mnt
efibootmgr --create --disk /dev/sdb --part 1 \
    --label "rEFInd (sdb, backup)" \
    --loader '\EFI\BOOT\BOOTX64.EFI'
```

## 8. Автохук синхронизации ESP: primary → backup

`/boot` на RAID1 синхронизируется автоматически средствами mdadm — хук нужен только для ESP,
которая вне массива. Синхронизация односторонняя: primary (`sda1`, смонтирован в `/boot/efi`) → backup (`sdb1`).

`/etc/pacman.d/hooks/95-refind-sync-efi.hook`:
```ini
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = linux-cachyos
Target = refind
Target = mkinitcpio

[Action]
Description = Sync primary ESP -> backup ESP disk
When = PostTransaction
Exec = /usr/local/bin/sync-efi-mirror.sh
```

`/usr/local/bin/sync-efi-mirror.sh`:
```bash
#!/bin/bash
set -euo pipefail

PRIMARY_ESP=/boot/efi
BACKUP_DEV=/dev/sdb1
MOUNT_POINT=/run/efi-backup-sync

mkdir -p "$MOUNT_POINT"
mount "$BACKUP_DEV" "$MOUNT_POINT"
trap 'umount "$MOUNT_POINT"; rmdir "$MOUNT_POINT"' EXIT

rsync -a --delete "$PRIMARY_ESP"/ "$MOUNT_POINT"/
```

```bash
chmod +x /usr/local/bin/sync-efi-mirror.sh
```

## 9. Финал

```bash
exit    # из chroot
umount -R /mnt
reboot
```

Убрать установочный носитель. В UEFI Boot Menu (P510 — F12 при старте) должны быть видны обе
записи rEFInd (sda/sdb).

## 10. Проверка отказоустойчивости

Перед вводом в прод:

1. Физически отключить один диск (машина выключена).
2. Загрузиться, в firmware Boot Menu выбрать запись оставшегося диска.
3. Убедиться, что оба mdraid-массива (`/boot` и `/`) поднимаются в degraded-режиме
   (`cat /proc/mdstat` покажет `[U_]` или `[_U]`), система грузится.
4. Подключить диск обратно, восстановить оба массива:
   ```bash
   mdadm --manage /dev/md0 --add /dev/sdX2
   mdadm --manage /dev/md1 --add /dev/sdX3
   ```
   дождаться ресинка (`watch cat /proc/mdstat`).
5. Пересоздать ESP на восстановленном диске (если раздел пересоздавался) и прогнать
   `sync-efi-mirror.sh` вручную — `/boot` восстановится сам через mdadm-ресинк, ESP — только
   через хук/скрипт, т.к. вне массива.

**Важный нюанс:** ESP-зеркалирование здесь — не live-mirror (не RAID), а синхронизация по
событию (обновление ядра/rEFInd). Если между двумя `pacman -Syu` с обновлением ядра отказал
основной диск до срабатывания хука — резервный ESP может отставать на одно обновление. Для
домашней лабы это приемлемый компромисс.
