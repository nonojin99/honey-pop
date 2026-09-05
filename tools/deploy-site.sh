#!/usr/bin/env bash
# 웹 빌드를 gh-pages 브랜치로 올린다. Render 정적 사이트가 이 브랜치를 서빙한다.
#
#   bash tools/deploy-site.sh            # 현재 build/web 을 올린다
#   bash tools/deploy-site.sh --build    # 웹 빌드를 다시 뽑고 올린다
#
# ★ gh(GitHub CLI)가 없어도 된다. 저장소가 이미 있으면 git push 만 하면 되고,
#   인증은 Windows 자격증명 관리자(GCM)가 처리한다.
#   저장소가 아직 없다면 github.com/new 에서 빈 저장소를 먼저 만들 것 (README 참고).
#
# 저장소 구조:
#   main      소스
#   gh-pages  웹 빌드만 루트에 — Render publishPath 가 여기를 가리킨다
set -euo pipefail

REPO_NAME="honey-pop"
OWNER="${GH_OWNER:-nonojin99}"
GODOT="${GODOT:-/e/Godot/Godot_v4.7.2-stable_win64.exe}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGES_WT="$ROOT/../hp-pages"
cd "$ROOT"

if [ "${1:-}" = "--build" ]; then
  echo "웹 빌드 중…"
  mkdir -p build/web
  "$GODOT" --headless --path . --export-release "Web" build/web/index.html >/dev/null 2>&1
  rm -f build/web/*.import
fi
[ -f build/web/index.wasm ] || { echo "build/web 이 비어 있습니다. --build 로 다시 실행하세요"; exit 1; }

git remote get-url origin >/dev/null 2>&1 \
  || git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"

if ! git ls-remote origin HEAD >/dev/null 2>&1; then
  echo "원격 저장소가 없습니다: https://github.com/$OWNER/$REPO_NAME"
  echo "github.com/new 에서 '$REPO_NAME' 을 public 으로, README·.gitignore 없이 비워서 만든 뒤 다시 실행하세요."
  exit 1
fi

# ── gh-pages 워크트리에 최신 빌드 반영 ──
[ -d "$PAGES_WT" ] || git worktree add --orphan -b gh-pages "$PAGES_WT" -q
find "$PAGES_WT" -maxdepth 1 -type f ! -name '.git' -delete
cp build/web/* "$PAGES_WT/"
touch "$PAGES_WT/.nojekyll"
( cd "$PAGES_WT"
  git add -A
  git diff --cached --quiet || git -c core.safecrlf=false commit -q -m "웹 빌드 갱신 ($(date '+%Y-%m-%d %H:%M'))

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" )

echo "push 중… (wasm 38MB 라 처음엔 몇 분 걸립니다)"
git push -u origin main
git -C "$PAGES_WT" push -u origin gh-pages

echo
echo "저장소  https://github.com/$OWNER/$REPO_NAME"
echo "gh-pages 브랜치에 웹 빌드가 올라갔습니다. Render 정적 사이트가 이걸 자동 배포합니다."
