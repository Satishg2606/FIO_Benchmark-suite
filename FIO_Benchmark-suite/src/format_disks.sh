#!/bin/bash
for d in /dev/sd{a..p}; do
  [ -b "$d" ] || continue
  echo "=== Creating partition on $d ==="
  parted -s $d mklabel gpt
  parted -s $d mkpart primary 0% 100%
done

echo "=== Re-reading partition table ==="
partprobe
sleep 2
echo "\n\n"
lsblk
echo "\n\n"
for p in /dev/sd{a..p}1; do
  [ -b "$p" ] || continue
  echo "=== Formatting $p ==="
  mkfs.ext4 -F $p
done
echo "\n\n"
lsblk
echo "\n\n"
for d in /dev/sd{a..p}; do
  [ -b "$d" ] || continue
  echo "=== Deleting partition on $d ==="
  parted -s $d rm 1
done

echo "\n \n"
lsblk
echo "\n"
echo "=== Final partition table refresh ==="
partprobe
