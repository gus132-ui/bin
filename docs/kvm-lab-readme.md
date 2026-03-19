# `KVM Lab Workflow`

**Purpose:**
Fast creation of disposable or persistent KVM labs with strong isolation,
no host contamination, and reversible state management.

---

## Directory Layout

```
/var/lib/libvirt/images/
├── base/
│   ├── debian13-template.qcow2
│   └── work01-base-YYYY-MM-DD_HHMMSS.qcow2
├── overlays/
│   └── work01.qcow2
├── lab/
│   └── <lab-name>.qcow2
├── whonix/
│   ├── Whonix-Gateway-*.qcow2
│   └── Whonix-Workstation-*.qcow2
└── archive/
```

---

## Installed Tools

| Script                | Location                           | Purpose                          |
| --------------------- | ---------------------------------- | -------------------------------- |
| `kvm-lab-create`      | `~/.local/bin/kvm-lab-create`      | Create lab VMs from chosen base  |
| `kvm-lab-destroy`     | `~/.local/bin/kvm-lab-destroy`     | Destroy lab VM + disk safely     |
| `kvm-promote-to-base` | `~/.local/bin/kvm-promote-to-base` | Freeze any VM into reusable base |
| `kvm--lab-status`     | `~/.local/bin/kvm-lab-status`      | Prints the current status        |
Ensure:

```
echo $PATH | grep "$HOME/.local/bin"
```

---

## Core Concepts

| Term       | Meaning                                          |
| ---------- | ------------------------------------------------ |
| Base image | Immutable qcow2 used as parent for new labs      |
| Overlay    | Writable qcow2 layer for a specific VM           |
| Promote    | Freeze a VM’s current disk state into a new base |

---

## Normal Workflow

### 1. Promote a VM into a base

Freeze current VM state for reuse.

```
virsh -c qemu:///system shutdown work01
kvm-promote-to-base work01
```

Creates:

```
/var/lib/libvirt/images/base/work01-base-YYYY-MM-DD_HHMMSS.qcow2
```

---

### 2. Create a new lab

From template:

```
kvm-lab-create lab10 --base template --start
```

From newest work01 base:

```
kvm-lab-create lab11 --base work01 --start
```

From specific base:

```
kvm-lab-create lab12 --base /var/lib/libvirt/images/base/work01-base-2026-01-09_150905.qcow2 --start
```

---

### 3. Destroy a lab safely

```
kvm-lab-destroy lab11
```

**Guards enforced:**

* Only deletes VMs whose disks are under `/var/lib/libvirt/images/lab/`
* Refuses to touch `work01`, template, Whonix, or base images

---

## Debugging & Verification

List all VMs:

```
virsh -c qemu:///system list --all
```

Check disk chain:

```
sudo qemu-img info --backing-chain /var/lib/libvirt/images/lab/lab10.qcow2
```

Confirm no base corruption:

```
sudo qemu-img info /var/lib/libvirt/images/base/work01-base-*.qcow2
```

---

## Invariants (Never Broken)

* `work01` remains intact
* Base images are never modified
* Lab VMs cannot access host or other VMs
* No filesystem passthrough
* All labs use NAT-only `default` network

---

## Recovery

Delete a bad base:

```
sudo rm /var/lib/libvirt/images/base/<base-file>.qcow2
```

Delete a stuck lab:

```
kvm-lab-destroy <lab-name>
```

---

## Philosophy

> **One-way operations**
> Promote → Create → Destroy
> Host always stays clean.


