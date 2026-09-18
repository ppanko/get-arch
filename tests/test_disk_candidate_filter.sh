#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmp_dir=$(mktemp -d)
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

awk '/^if \[\[ \$\(tty\) != \/dev\/tty1 \]\]; then$/ { exit } { print }' \
  archiso/get-arch-install > "$tmp_dir/functions.sh"

mkdir -p "$tmp_dir/bin"
cat > "$tmp_dir/bin/lsblk" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$LSBLK_JSON"
SH
chmod +x "$tmp_dir/bin/lsblk"
PATH="$tmp_dir/bin:$PATH"
export PATH

# shellcheck source=/dev/null
source "$tmp_dir/functions.sh"

export LSBLK_JSON='{"blockdevices":[{"path":"/dev/nvme0n1","type":"disk","rm":false,"hotplug":false,"tran":"nvme","size":500000000000,"model":"Internal SSD","mountpoints":[null],"children":[]}]}'
output=$(list_disk_candidates)
[[ $output == /dev/nvme0n1$'\t'* ]] || fail 'eligible non-removable NVMe disk was not returned'

export LSBLK_JSON='{"blockdevices":[{"path":"/dev/nvme0n1","type":"disk","rm":false,"hotplug":true,"tran":"nvme","size":500000000000,"model":"Hotplug SSD","mountpoints":[null],"children":[]}]}'
output=$(list_disk_candidates)
[[ -z $output ]] || fail 'hot-pluggable disk was eligible for automation'

export LSBLK_JSON='{"blockdevices":[{"path":"/dev/sda","type":"disk","rm":false,"hotplug":false,"tran":"iscsi","size":500000000000,"model":"Remote LUN","mountpoints":[null],"children":[]}]}'
output=$(list_disk_candidates)
[[ -z $output ]] || fail 'iSCSI disk was eligible for automation'

export LSBLK_JSON='{"blockdevices":[{"path":"/dev/nbd0","type":"disk","rm":false,"hotplug":false,"tran":null,"size":500000000000,"model":null,"mountpoints":[null],"children":[]}]}'
output=$(list_disk_candidates)
[[ -z $output ]] || fail 'network block device was eligible for automation'

export LSBLK_JSON='{"blockdevices":[{"path":"/dev/rbd0","type":"disk","rm":false,"hotplug":false,"tran":null,"size":500000000000,"model":"Ceph RBD","mountpoints":[null],"children":[]}]}'
output=$(list_disk_candidates)
[[ -z $output ]] || fail 'Ceph RBD device was eligible for automation'

export LSBLK_JSON='{"blockdevices":[{"path":"/dev/nvme0n1","type":"disk","rm":false,"hotplug":null,"tran":"nvme","size":500000000000,"model":"Unknown hotplug state","mountpoints":[null],"children":[]}]}'
output=$(list_disk_candidates)
[[ -z $output ]] || fail 'disk with unknown hotplug state was eligible for automation'

export LSBLK_JSON='{"blockdevices":[{"path":"/dev/nvme0n1","type":"disk","rm":false,"hotplug":false,"tran":"nvme","size":500000000000,"model":null,"mountpoints":[null],"children":[]}]}'
output=$(list_disk_candidates)
[[ $output == $'/dev/nvme0n1\t465.7 GiB\tunknown\tnvme' ]] || fail 'empty model did not preserve candidate metadata fields'

printf 'ok\n'
