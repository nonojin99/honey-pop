#!/usr/bin/env bash
# GitHub Pages 배포 — 저장소 생성 · 두 브랜치 push · Pages 활성화까지 한 번에.
#
#   bash tools/deploy-pages.sh          # 현재 build/web 을 그대로 올린다
#   bash tools/deploy-pages.sh --build  # 웹 빌드를 다시 뽑고 올린다
#
# 미리 `gh auth login` 이 되어 있어야 한다 (브라우저 인증이라 사람이 한 번 해야 한다).
# 저장소 구조:
#   main      소스
#   gh-pages  웹 빌드만 루트에 (Pages 가 서빙하는 브랜치)
set -euo pipefail

REPO_NAME="honey-pop"
DESC="허니 팝 — 조준 정밀도 × 꽃가루 게이지의 2축 퍼즐 슈터 (Godot 4.7)"
GODOT="${GODOT:-/e/Godot/Godot_v4.7.2-stable_win64.exe}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGES_WT="$ROOT/../hp-pages"
cd "$ROOT"

GH="$(command -v gh || true)"
[ -z "$GH" ] && GH="/c/Users/nonoj/AppData/Local/Microsoft/WinGet/Packages/GitHub.cli_Microsoft.Winget.Source_8wekyb3d8bbwe/bin/gh.exe"
[ -x "$GH" ] || { echo "gh 를 찾을 수 없습니다"; exit 1; }

if ! "$GH" auth status >/dev/null 2>&1; then
  echo "GitHub 로그인이 필요합니다. 먼저 이걸 실행하세요:"
  echo "  gh auth login --hostname github.com --git-protocol https --web"
  exit 1
fi

OWNER="$("$GH" api user -q .login)"
echo "계정: $OWNER"

if [ "${1:-}" = "--build" ]; then
  echo "웹 빌드 중…"
  mkdir -p build/web
  "$GODOT" --headless --path . --export-release "Web" build/web/index.html >/dev/null 2>&1
  rm -f build/web/*.import
fi
[ -f build/web/index.wasm ] || { echo "build/web 이 비어 있습니다. --build 로 다시 실행하세요"; exit 1; }

# ── 저장소 ──
if "$GH" repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  echo "저장소가 이미 있습니다: $OWNER/$REPO_NAME"
else
  echo "저장소 생성 중…"
  "$GH" repo create "$REPO_NAME" --public --description "$DESC" --disable-wiki
fi
git remote get-url origin >/dev/null 2>&1 \
  || git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"

# ── gh-pages 워크트리에 최신 빌드 반영 ──
if [ ! -d "$PAGES_WT" ]; then
  git worktree add --orphan -b gh-pages "$PAGES_WT" -q
fi
find "$PAGES_WT" -maxdepth 1 -type f ! -name '.git' -delete
cp build/web/* "$PAGES_WT/"
touch "$PAGES_WT/.nojekyll"
( cd "$PAGES_WT"
  git add -A
  git diff --cached --quiet || git -c core.safecrlf=false commit -q -m "웹 빌드 갱신 ($(date +%Y-%m-%d\ %H:%M))

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" )

# ── push ──
echo "push 중… (wasm 38MB 라 처음엔 몇 분 걸립니다)"
git push -u origin main
git -C "$PAGES_WT" push -u origin gh-pages

# ── Pages 활성화 ──
echo "Pages 설정 중…"
"$GH" api -X POST "repos/$OWNER/$REPO_NAME/pages" \
  -f "source[branch]=gh-pages" -f "source[path]=/" >/dev/null 2>&1 \
|| "$GH" api -X PUT "repos/$OWNER/$REPO_NAME/pages" \
  -f "source[branch]=gh-pages" -f "source[path]=/" >/dev/null 2>&1 \
|| echo "  (이미 설정돼 있거나 수동 설정이 필요합니다: Settings → Pages → gh-pages / root)"

echo
echo "저장소   https://github.com/$OWNER/$REPO_NAME"
echo "플레이   https://$OWNER.github.io/$REPO_NAME/"
echo "(첫 배포는 반영까지 1~2분 걸립니다)"
