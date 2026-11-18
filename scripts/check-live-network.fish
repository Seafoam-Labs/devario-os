#!/usr/bin/env fish
#
# check-live-network.fish — Devario OS live-session network detection check.
#
# Paste this whole file into a terminal on the live USB and press Enter.
# It runs immediately and will NOT close your terminal.
#
# Alternatively save it as check-live-network.fish and run:
#
#     fish check-live-network.fish
#
# To save a report to send back for support:
#
#     fish check-live-network.fish 2>&1 | tee net-report.txt
#
# For the full kernel log, save the file and run it with sudo:
#
#     sudo fish check-live-network.fish
#
# The result is also in $status: 0 = detected and working
#                                1 = detected but not usable
#                                2 = no network hardware detected
#
# Read-only: nothing is changed on the system.

function cln_section
    printf '\n== %s ==\n' $argv[1]
end

function cln_have
    command -v $argv[1] >/dev/null 2>&1
end

function cln_loggrep
    set -l out (printf '%s\n' $argv[2] | grep -iE $argv[1] | tail -n 20)
    if test (count $out) -gt 0
        printf '%s\n' $out | sed 's/^/    /'
    else
        printf '    (no matching messages)\n'
    end
end

function check-live-network
    set -l hw_total 0
    set -l hw_nodriver 0
    set -l phys_ifaces 0
    set -l link_up 0
    set -l with_ip 0
    set -l wifi_blocked 0
    set -l nodriver_lines

    cln_section System
    printf 'Kernel : %s\n' (uname -r)
    printf 'Date   : %s\n' (date)
    if test -r /etc/os-release
        set -l osname (sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -n1)
        test -n "$osname"; and printf 'OS     : %s\n' $osname
    end

    cln_section "PCI network devices"
    set -l pci_found 0
    for d in (find /sys/bus/pci/devices -mindepth 1 -maxdepth 1 2>/dev/null | sort)
        test -r $d/class; or continue
        set -l class (cat $d/class)
        string match -q '0x02*' $class; or continue
        set pci_found 1
        set hw_total (math $hw_total + 1)
        set -l slot (basename $d)
        set -l vendor (cat $d/vendor 2>/dev/null; or echo '?')
        set -l device (cat $d/device 2>/dev/null; or echo '?')
        set -l drv none
        if test -L $d/driver
            set drv (basename (readlink -f $d/driver))
        end
        printf '%s  [%s:%s]  driver: %s\n' $slot $vendor $device $drv
        if cln_have lspci
            lspci -nnks $slot 2>/dev/null | sed 's/^/    /'
        end
        if test "$drv" = none
            set hw_nodriver (math $hw_nodriver + 1)
            set -a nodriver_lines "PCI $slot [$vendor:$device]"
            set -l modalias (cat $d/modalias 2>/dev/null)
            printf '    modalias: %s\n' "$modalias"
            if cln_have modprobe; and test -n "$modalias"
                set -l matches (modprobe -R $modalias 2>/dev/null)
                if test (count $matches) -gt 0
                    printf '    matching modules available: %s\n' (string join ' ' $matches)
                    printf '    try: sudo modprobe %s\n' $matches[1]
                else
                    printf '    NO module in this kernel matches this device\n'
                end
            end
        end
    end
    test $pci_found -eq 0; and printf 'none found\n'

    cln_section "USB network devices"
    set -l usb_found 0
    for d in (find /sys/bus/usb/devices -mindepth 1 -maxdepth 1 2>/dev/null | sort)
        test -r $d/idVendor; or continue
        set -l vid (cat $d/idVendor)
        set -l pid (cat $d/idProduct)
        test "$vid" = 1d6b; and continue # root hub, not a device
        set -l is_net 0
        set -l drv none
        set -l names
        for iface in (find $d -mindepth 1 -maxdepth 1 -name '*:*' 2>/dev/null | sort)
            test -r $iface/bInterfaceClass; or continue
            set -l cls (cat $iface/bInterfaceClass)
            set -l sub (cat $iface/bInterfaceSubClass 2>/dev/null; or echo 00)
            set -l proto (cat $iface/bInterfaceProtocol 2>/dev/null; or echo 00)
            # e0/01/01 is Bluetooth, not a network card
            if test "$cls" = e0; and test "$sub" = 01; and test "$proto" = 01
                continue
            end
            for nd in (find $iface/net -mindepth 1 -maxdepth 1 2>/dev/null)
                set is_net 1
                set -a names (basename $nd)
            end
            switch $cls
                case 02 0a e0
                    set is_net 1
            end
            if test $is_net -eq 1; and test -L $iface/driver
                set drv (basename (readlink -f $iface/driver))
            end
        end
        test $is_net -eq 1; or continue
        set usb_found 1
        set hw_total (math $hw_total + 1)
        set -l names_str (string join ' ' $names)
        test -n "$names_str"; or set names_str none
        printf '%s:%s  driver: %s  interfaces: %s\n' $vid $pid $drv $names_str
        if test "$drv" = none
            set hw_nodriver (math $hw_nodriver + 1)
            set -a nodriver_lines "USB $vid:$pid"
        end
    end
    test $usb_found -eq 0; and printf 'none found\n'
    if cln_have lsusb
        printf '\nFull USB device list (for reference):\n'
        lsusb | sed 's/^/    /'
    end

    cln_section "Network interfaces"
    if cln_have ip
        ip -brief link 2>/dev/null | sed 's/^/    /'
        printf '\n'
    end
    for n in (find /sys/class/net -mindepth 1 -maxdepth 1 2>/dev/null | sort)
        set -l ifname (basename $n)
        test "$ifname" = lo; and continue
        set -l state (cat $n/operstate 2>/dev/null; or echo unknown)
        set -l carrier (cat $n/carrier 2>/dev/null; or echo n/a)
        set -l drv unknown
        set -l bus virtual
        if test -e $n/device
            set -l devpath (readlink -f $n/device)
            set bus other
            if string match -q '*pci*' $devpath
                set bus pci
            else if string match -q '*usb*' $devpath
                set bus usb
            end
            if test -L $n/device/driver
                set drv (basename (readlink -f $n/device/driver))
            end
        end
        set -l wireless no
        if test -d $n/phy80211; or test -d $n/wireless
            set wireless yes
        end
        set -l ipv4_str none
        if cln_have ip
            set -l ipv4 (ip -4 -o addr show dev $ifname 2>/dev/null | awk '{print $4}')
            set ipv4_str (string join ' ' $ipv4)
            test -n "$ipv4_str"; or set ipv4_str none
        end
        printf '%s: bus=%s driver=%s wireless=%s state=%s carrier=%s ipv4=%s\n' $ifname $bus $drv $wireless $state $carrier $ipv4_str
        if test "$bus" != virtual
            set phys_ifaces (math $phys_ifaces + 1)
            test "$carrier" = 1; and set link_up (math $link_up + 1)
            test "$ipv4_str" != none; and set with_ip (math $with_ip + 1)
        end
    end
    test $phys_ifaces -eq 0; and printf 'No physical network interfaces present.\n'

    cln_section "Wireless kill switches (rfkill)"
    set -l rfkill_found 0
    for r in (find /sys/class/rfkill -mindepth 1 -maxdepth 1 2>/dev/null | sort)
        test -r $r/type; or continue
        set rfkill_found 1
        set -l rtype (cat $r/type)
        set -l soft (cat $r/soft 2>/dev/null; or echo 0)
        set -l hard (cat $r/hard 2>/dev/null; or echo 0)
        printf '%s: type=%s soft-blocked=%s hard-blocked=%s\n' (basename $r) $rtype $soft $hard
        if test "$rtype" = wlan
            if test "$soft" = 1; or test "$hard" = 1
                set wifi_blocked 1
            end
        end
    end
    test $rfkill_found -eq 0; and printf 'no rfkill devices (no wireless, or not detected)\n'

    cln_section "Kernel log (network-related)"
    set -l dmesg_out (dmesg 2>/dev/null | string collect)
    if test -n "$dmesg_out"
        printf 'Firmware load problems:\n'
        cln_loggrep 'firmware.*(fail|error|missing|not found|timeout|unable|cannot)|(fail|error|missing|unable|cannot).*firmware' "$dmesg_out"
        printf 'Driver probe problems:\n'
        cln_loggrep 'probe.*(fail|error)|failed to (load|probe|initialize)|unknown symbol|disagrees about version' "$dmesg_out"
        printf 'Network driver activity:\n'
        cln_loggrep 'iwlwifi|ath[0-9k]|rtl|rtw|r816|r815|e1000|igb|ixgbe|bnx|tg3|mlx|virtio_net|cdc_ether|asix|smsc|lan78|ax88|mt76|mt79|brcm|renamed|link is|link up|link down' "$dmesg_out"
    else
        printf 'dmesg not readable; save this script and rerun with sudo for kernel messages\n'
    end

    cln_section NetworkManager
    if cln_have systemctl
        set -l nmstate (systemctl is-active NetworkManager 2>/dev/null)
        test -n "$nmstate"; or set nmstate unknown
        printf 'service: %s\n' $nmstate
    end
    if cln_have nmcli
        nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null | sed 's/^/    /'
        printf 'radios: %s\n' (nmcli -t -f WIFI,WWAN radio 2>/dev/null | string join ' ')
    else
        printf 'nmcli not available\n'
    end

    cln_section Verdict
    if test $hw_nodriver -gt 0; and test $phys_ifaces -gt 0
        printf 'Note: some detected devices have no driver bound:\n'
        printf '%s\n' $nodriver_lines | sed 's/^/    /'
    end

    if test $hw_total -eq 0; and test $phys_ifaces -eq 0
        printf 'NOT DETECTED: no network hardware found on PCI or USB.\n'
        printf '  - Check BIOS/UEFI: the onboard NIC / WLAN may be disabled.\n'
        printf '  - In a VM: make sure a network adapter is attached.\n'
        printf '  - USB adapter: try a different port.\n'
        return 2
    end

    if test $hw_nodriver -gt 0; and test $phys_ifaces -eq 0
        printf 'DETECTED, but no kernel driver is bound:\n'
        printf '%s\n' $nodriver_lines | sed 's/^/    /'
        printf '  The kernel on this ISO appears to lack a module for this device.\n'
        printf '  Send the vendor:device IDs and modalias lines above for a kernel/driver fix.\n'
        return 1
    end

    if test $link_up -gt 0
        if test $with_ip -gt 0
            printf 'DETECTED and working: at least one interface has link and an IPv4 address.\n'
            printf '  If browsing still fails, the problem is above the NIC (DNS, route, captive portal).\n'
            test $wifi_blocked -eq 1; and printf '  Note: wireless is rfkill-blocked; wired is up.\n'
            return 0
        end
        printf 'DETECTED: link is up but no IPv4 address was assigned (DHCP problem).\n'
        printf '  Try: nmcli device connect <iface>   or check the DHCP server / cable.\n'
        return 1
    end

    if test $wifi_blocked -eq 1
        printf 'DETECTED, but wireless is blocked by rfkill.\n'
        printf '  Try: sudo rfkill unblock wifi   (also check the hardware wifi switch / Fn key)\n'
        return 1
    end

    if test $phys_ifaces -gt 0
        printf 'DETECTED, but no interface has link (down / no carrier).\n'
        printf '  Try: sudo ip link set <iface> up\n'
        printf '  Ethernet: check cable/switch. Wi-Fi: connect to an AP (nmcli / nm-connection-editor).\n'
        return 1
    end

    printf 'DETECTED (hardware present), but no network interface was created.\n'
    printf '  Usually a firmware load failure — see the kernel log section above.\n'
    return 1
end

check-live-network