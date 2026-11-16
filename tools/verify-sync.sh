#!/bin/bash
# tools/verify-sync.sh -- a sync that stopped is not a sync that finished (08-18).
# Read-only. Prints one line per check and a final VERIFY OK / VERIFY FAIL.
#
#   TOP=/mnt/Data/lineage-23.2 (default)   STATUS=0 skips the slow `repo status`
#
# Checks, each one a trap met before:
#   1. every manifest project has a worktree whose HEAD resolves
#   2. every project is still shallow (a retry into a half-fetched dir goes full depth)
#   3. git-lfs payloads are real files, not pointers (chromium-webview came EMPTY 08-18)
#   4. no tmp_pack_* left by a stalled fetch (stale ones are deleted only after 1-2 pass)
#   5. the ROM (rom.conf ROM_OWNERS), not LineageOS, owns build/make + build/soong (a re-pointed
#      checkout builds the wrong ROM: AICP 11-12 (g))
#   6. `repo status`: no torn worktree (a power cut can tear a checkout without touching its gitdir);
#      a build host's own patch passes only on an exact per-file diff hash (tools/host-patches.txt)
set -u
TOP="${TOP:-/mnt/Data/lineage-23.2}"
STATUS="${STATUS:-1}"
REC="$(cd "$(dirname "$0")/.." && pwd)"     # before the cd below: $0 may be relative
[ -f "$REC/tree-edits.txt" ] || { echo "FAIL  no $REC/tree-edits.txt"; exit 2; }
cd "$TOP" || exit 2
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
bad(){ echo "FAIL  $*"; fail=1; }
ok(){ echo "ok    $*"; }

repo list 2>/dev/null | sed 's/ : / /' > "$W/projects"
n=$(wc -l < "$W/projects")
[ "$n" -gt 1000 ] || bad "repo list gave only $n projects"

# 1 + 2
nowt=0; nohead=0; deep=0
while read -r path name; do
  if [ ! -e "$path/.git" ]; then echo "      no worktree: $path ($name)"; nowt=$((nowt+1)); continue; fi
  git -C "$path" rev-parse -q --verify HEAD >/dev/null 2>&1 || { echo "      no HEAD: $path"; nohead=$((nohead+1)); continue; }
  gd=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null)
  [ -f "$gd/shallow" ] || { echo "      not shallow: $path"; deep=$((deep+1)); }
done < "$W/projects"
[ $nowt -eq 0 ] && [ $nohead -eq 0 ] && ok "$n projects, all with a worktree and a HEAD" || bad "worktrees: $nowt missing, $nohead without HEAD"
[ $deep -eq 0 ] && ok "all $n shallow" || bad "$deep project(s) went full depth"

# 3 -- positive control: chromium-webview is known to use LFS; finding 0 LFS projects is a failure
: > "$W/lfs"
while read -r path name; do
  git -C "$path" grep -q -e "filter=lfs" -- ':(glob)**/.gitattributes' 2>/dev/null && echo "$path" >> "$W/lfs"
done < "$W/projects"
grep -q chromium-webview "$W/lfs" || bad "LFS detection found no chromium-webview project (detector broken?)"
lfsbad=0
while read -r p; do
  if (cd "$p" && git lfs ls-files 2>/dev/null | grep -q ' - '); then echo "      LFS pointer only: $p"; lfsbad=$((lfsbad+1)); fi
done < "$W/lfs"
[ $lfsbad -eq 0 ] && ok "$(wc -l < "$W/lfs") LFS project(s), every payload present" || bad "$lfsbad LFS project(s) hold pointers (git lfs pull there)"

# 4
find .repo/projects .repo/project-objects -name 'tmp_pack_*' -printf '%TY-%Tm-%Td %TH:%TM %10s %p\n' 2>/dev/null > "$W/tmp"
[ -s "$W/tmp" ] && { bad "$(wc -l < "$W/tmp") stale tmp_pack_*:"; sed 's/^/      /' "$W/tmp"; } || ok "no tmp_pack_*"

# 5
. "$REC/rom.conf" || { echo "FAIL  no $REC/rom.conf"; exit 2; }
for p in $ROM_OWNERS; do
  path=${p%%:*}; want=${p#*:}
  got=$(awk -v p="$path" '$1==p{print $2}' "$W/projects")
  [ "$got" = "$want" ] && ok "$path = $got" || bad "$path = '$got', expected $want"
done

# 6
if [ "$STATUS" = "1" ]; then
  repo status -j"$(nproc)" > "$W/status" 2>&1
  # The recipe's own tree edits (tree-edits.txt: one path per line, relative to TOP) are the
  # only changes allowed; a project counts as dirty if anything ELSE is changed in it.
  dirty=0; hostp=""
  for p in $(sed -n 's/^project \([^ ]*\)\/ .*/\1/p' "$W/status"); do
    other=$(git -C "$p" status --porcelain --untracked-files=all | sed "s|^...|$p/|" \
            | grep -vxF -f <(grep -v '^#' "$REC/tree-edits.txt" 2>/dev/null) || true)
    # a build host's own patch (host-patches.txt) passes only on an exact per-file diff hash
    rest=""
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      f=${line#"$p/"}; want=$(awk -v f="$line" '$1==f{print $2}' "$REC/tools/host-patches.txt" 2>/dev/null)
      if [ -n "$want" ] && [ "$(git -C "$p" diff -- "$f" | sha256sum | cut -d' ' -f1)" = "$want" ]; then
        hostp="$hostp $line"
      else
        rest="$rest$line"$'\n'
      fi
    done <<< "$other"
    [ -z "$rest" ] && continue
    dirty=$((dirty+1)); echo "      dirty: $p"; printf '%s' "$rest" | sed 's/^/        /'
  done
  [ -n "$hostp" ] && ok "host patch(es) accepted by exact hash (tools/host-patches.txt):$hostp"
  [ "$dirty" -eq 0 ] && ok "repo status: every worktree clean (recipe edits excepted: tree-edits.txt)" || bad "repo status: $dirty dirty project(s)"
else
  echo "skip  repo status (STATUS=0)"
fi

[ $fail -eq 0 ] && echo "VERIFY OK" || echo "VERIFY FAIL"
exit $fail
