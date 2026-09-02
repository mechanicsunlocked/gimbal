# The LUKS prompt on a folded machine — analysis, no changes made

The question: can an on-screen keyboard appear at the disk-unlock prompt, so
a folded Framework 12 boots without a physical keyboard? Everything below was
read off this machine on 2026-09-02; nothing outside `$HOME` was changed, and
every command that would change something is written out for a human to run
or refuse.

## What the prompt is, here

    $ cat /proc/cmdline
    cryptdevice=PARTUUID=…:root root=/dev/mapper/root … quiet splash …
    $ cat /etc/mkinitcpio.conf.d/omarchy_hooks.conf | head -1
    HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs)
    $ pacman -Q plymouth limine
    plymouth 26.134.222-2
    limine 12.6.0-1

The root filesystem is LUKS (`nvme0n1p2 crypto_LUKS` → `/dev/mapper/root`,
btrfs). The prompt is Omarchy's Plymouth theme (`omarchy.script`, with
`entry.png` and `lock.png`), driven by mkinitcpio's classic **`encrypt`**
hook, which calls `plymouth ask-for-password` and hands the answer to
`cryptsetup`. This is the busybox initramfs, not the systemd one: there is no
`sd-encrypt`, no `systemd-cryptsetup`, and the `encrypt` hook has no notion
of TPM2 or FIDO2 tokens (`grep -i 'tpm\|fido\|token' /usr/lib/initcpio/hooks/encrypt`
finds nothing).

## Why a keyboard cannot be drawn there

Plymouth reads its input from the kernel console — keyboard only. Its
plugin set here (`details, fade-throbber, script, space-flares, text, tribar,
two-step`) contains nothing that opens an evdev device, and `strings` over
`plymouthd` and every plugin finds no `touch`, `evdev` or `libinput`. A
Plymouth script theme can draw a keyboard picture; it cannot receive a
finger. Adding that would mean a new Plymouth input plugin in C, installed
as root, rebuilt into the initramfs — the exact shape of fragility this
project was started to avoid, on the one screen where a mistake means a
machine that does not boot.

The physical keyboard, on the other hand, works at that prompt even when the
machine is folded: the thing that switches it off in tablet mode is libinput
(FINDINGS 1.6), and there is no libinput in the initramfs. Typing on a
keyboard that is folded behind the screen is awkward, not impossible.

## What actually answers the question

Not a keyboard: **not being asked**. Three routes exist; the first is the
one that fits.

### 1. Bind the passphrase to the TPM (recommended, needs root and a decision)

The machine has a TPM 2.0 (`/dev/tpmrm0`, `INTC6001`, `tpm_crb_acpi`), and
`systemd-cryptenroll` can seal a LUKS key slot to it so the disk unlocks at
boot without a prompt while the firmware and boot chain are unchanged, and
still falls back to the passphrase when they are not. Omarchy boots a UKI
through limine, which is the arrangement this was designed for.

The cost is the initramfs: `systemd-cryptenroll`'s TPM2 slot is unlocked by
`systemd-cryptsetup`, i.e. the **`sd-encrypt`** hook in a **systemd**
initramfs. Omarchy's `omarchy_hooks.conf` sets `udev … encrypt`; switching
means a later-sorting drop-in that rewrites `HOOKS` to
`(base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck btrfs-overlayfs)`
and a kernel command line that says `rd.luks.name=<UUID>=root` instead of
`cryptdevice=…`, plus `mkinitcpio -P`. Two things to weigh before that:

- Omarchy owns `omarchy_hooks.conf` and may rewrite it on update; a drop-in
  that sorts after it (`zz-fw12-systemd.conf`) survives that, but every
  Omarchy change to the hook list has to be re-read against it.
- The `resume=` hibernation path and `btrfs-overlayfs` (Omarchy's snapshot
  hook) both have to keep working under the systemd hooks. Neither is
  exotic; both must be tried on a machine with a second way in.

Then, once booted through the systemd initramfs:

    sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p2
    # or, to require a PIN as well (typed on the physical keyboard, but short):
    sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=yes /dev/nvme0n1p2

PCR 7 binds to the Secure Boot policy, so a changed boot chain falls back to
the passphrase. The passphrase slot stays; nothing is removed.

**What it changes about security, stated plainly:** with no PIN, a stolen
laptop boots to the lock screen by itself — the disk no longer protects
against someone who has the whole machine, only against someone who has the
drive. The lock screen (Phase 4) becomes the guard. That is the ordinary
trade every TPM-unlocked laptop makes; it is a decision, not a default.

### 2. A key on a USB stick (no initramfs change)

The `encrypt` hook already supports `cryptkey=<device>:<fstype>:<path>`: add
a key file as a second LUKS slot, put it on a small USB stick, and the prompt
is skipped whenever the stick is present. Root for `cryptsetup luksAddKey`
and the command line; no hook change. Cheap, and a stick in the side of a
tablet is exactly as inconvenient as it sounds.

### 3. FIDO2 (not applicable here)

Omarchy's `omarchy-setup-security-fido2` configures `pam_u2f` for sudo and
polkit — it does nothing for LUKS — and no FIDO2 device is present
(`systemd-cryptenroll --fido2-device=list`: none). It would also need the
same `sd-encrypt` switch as route 1.

## Recommendation

Route 1 with a PIN, if the security trade is acceptable; route 1 without one
if the lock screen is judged guard enough. Either way it is a root change to
the boot path, made once, with the passphrase kept as the way back — and it
should be done with the machine unfolded and a USB installer within reach,
because the first boot after `mkinitcpio -P` is the one that tells you
whether the systemd hooks agree with `resume=` and the snapshot overlay here.

Not done in this session: none of it is in `$HOME`, and all of it needs a
human's yes.
