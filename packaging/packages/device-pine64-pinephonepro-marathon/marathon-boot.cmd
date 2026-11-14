# Marathon PinePhone Pro U-Boot script (bring-up, not validated on hardware).
#
# Based on the PinePhone script, with the A64 parts replaced by their
# RK3399 equivalents and the kernel arguments changed so Plymouth shows the
# Marathon splash on the panel instead of a text console:
#
#   * console=tty1                kernel output on the panel VT
#   * splash                      Plymouth takes the display
#   * plymouth.ignore-serial-consoles
#                                 the serial console below would otherwise
#                                 force Plymouth's text-only splash
#   * vt.global_cursor_default=0  no VT cursor blinking behind the splash
#
# Serial console: RK3399 debug UART2 (0xff1a0000) at 115200 baud (as in
# pmaports' deviceinfo_getty), routed to the 3.5 mm jack by a DIP switch
# (schematic sheets 11 and 22).
#
# Boot progress, as on the PinePhone: green LED and a vibration pulse at
# start, red added (yellow) once the kernel is loaded, blue added (white)
# and the vibration stopped just before booting.
#
# 1 MiB of RAM at 0x3ff00000 is reserved for pstore/ramoops so the kernel
# log survives a watchdog reset. The RK3399 root node uses 2 address cells.
#
# U-Boot tries extlinux.conf before boot.scr: the image must not ship a
# /boot/extlinux/extlinux.conf, or this script is never run.
#
# Compiled to /boot/boot.scr by mkosi.finalize, replacing the stock one.

# GPIOs (schematic 20211127, sheets 11 and 17), all active high.
# U-Boot number = bank*32 + group*8 + pin (A=0 .. D=3). Check with
# 'gpio status -a' in the U-Boot console.
#   LED-R   GPIO4_D2 = 154
#   LED-G   GPIO4_D5 = 157
#   LED-B   GPIO4_D6 = 158
#   VIB_CTL GPIO3_B1 = 105
setenv led_r 154
setenv led_g 157
setenv led_b 158
setenv vib 105

gpio set ${vib}
gpio set ${led_g}

# U-Boot numbers the MMC devices differently from Linux.
# Linux side: eMMC = mmcblk2 (pmaports deviceinfo_dev_internal_storage),
# microSD = mmcblk0 (assumed). U-Boot side, TO VERIFY with 'mmc list':
#   U-Boot mmc 1 = microSD, U-Boot mmc 0 = eMMC
if test ${devnum} -eq 1 ; then
    echo "Booting from SD";
    setenv linuxdev 0;
else
    echo "Booting from eMMC";
    setenv linuxdev 2;
fi;

# Fall back to the DTB named in pmaports' deviceinfo_dtb if U-Boot did not
# set fdtfile itself.
if test -z "${fdtfile}"; then
    setenv fdtfile rockchip/rk3399-pinephone-pro.dtb;
fi;

setenv bootargs init=/init.sh rw console=tty1 console=ttyS2,115200n8 earlycon=uart8250,mmio32,0xff1a0000 panic=10 consoleblank=0 splash plymouth.ignore-serial-consoles loglevel=1 vt.global_cursor_default=0 PMOS_FORCE_PARTITION_RESIZE pmos_boot=/dev/mmcblk${linuxdev}p1 pmos_root=/dev/mmcblk${linuxdev}p2

printenv

echo Loading DTB
load ${devtype} ${devnum}:1 ${fdt_addr_r} ${fdtfile}
fdt addr ${fdt_addr_r}
fdt resize 2048

echo Reserving pstore RAM
fdt get name rmname /reserved-memory
if test $? -ne 0 ; then
    fdt mknode / reserved-memory
    fdt set /reserved-memory "#address-cells" <2>
    fdt set /reserved-memory "#size-cells" <2>
    fdt set /reserved-memory ranges
fi
fdt mknode /reserved-memory ramoops@3ff00000
fdt set /reserved-memory/ramoops@3ff00000 compatible "ramoops"
fdt set /reserved-memory/ramoops@3ff00000 reg <0x0 0x3ff00000 0x0 0x100000>
fdt set /reserved-memory/ramoops@3ff00000 no-map
fdt set /reserved-memory/ramoops@3ff00000 record-size <0x20000>
fdt set /reserved-memory/ramoops@3ff00000 console-size <0x40000>
fdt set /reserved-memory/ramoops@3ff00000 pmsg-size <0x20000>
fdt set /reserved-memory/ramoops@3ff00000 ecc-size <16>

echo Loading Initramfs
load ${devtype} ${devnum}:1 ${ramdisk_addr_r} initramfs
setenv ramdisk_size ${filesize}

echo Loading Kernel
load ${devtype} ${devnum}:1 ${kernel_addr_r} vmlinuz

gpio set ${led_r}

echo Loading user script
load ${devtype} ${devnum}:1 ${pxefile_addr_r} user.scr
if test $? -eq 0; then source ${pxefile_addr_r}; else echo No user script found; fi

echo Booting kernel
gpio set ${led_b}
gpio clear ${vib}
booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
