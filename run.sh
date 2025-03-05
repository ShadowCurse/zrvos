#!/bin/bash
set -xue

# QEMU file path
QEMU=qemu-system-riscv32

# Start QEMU
$QEMU -machine virt -bios default -nographic -serial mon:stdio --no-reboot \
  -kernel ./zig-out/bin/zrvos \
  -drive id=drive0,file=text.txt,format=raw,if=none \
  -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
  -global virtio-mmio.force-legacy=false
