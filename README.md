# 허니 팝 (honey-pop) — Godot 4.7

Puzzle Bobble 계열. 육각 격자가 원래 벌집 모양이라는 점을 그대로 세계관으로 썼다.
위에서 굳어 내려오는 벌집을 아기 벌이 꽃가루 구슬로 쏘아 같은 색 3개를 모으면 꿀이 되어 떨어진다.

- **혼자 하기** — 라운드가 오를수록 색이 늘고 줄이 두꺼워진다
- **대결하기** — 1 VS 1 / 2 VS 2 온라인 매칭. 큰 덩어리를 떨어뜨릴수록 상대에게 방해 구슬이 간다

## 애플에서도 설치되나 (프로젝트 시작 시의 질문)

**된다. 단, 빌드하는 시점에 macOS 가 필요하다.**

| | Android | iOS |
|---|---|---|
| Godot 공식 export | ✅ | ✅ |
| Windows 에서 빌드 | ✅ APK/AAB | ❌ **불가** |
| 필요한 것 | Android SDK + JDK + keystore | **macOS + Xcode** |
| 스토어 등록비 | $25 (1회) | $99/년 (Apple Developer Program) |

핵심은 **Godot 의 iOS export 산출물이 .ipa 가 아니라 Xcode 프로젝트**라는 점이다. 서명·빌드는
macOS 에서만 된다. 그래서 이 저장소에는 iOS 프리셋이 없다 — 빠뜨린 게 아니라 이 PC(Windows)에서
만들 수 없기 때문이다.

Mac 이 없을 때의 우회로:
- **내 기기에만 설치해 테스트** → Mac + 무료 Apple ID 로 7일짜리 프로비저닝 (7일마다 재설치)
- **Mac 없이** → GitHub Actions 의 macOS 러너나 Codemagic 같은 클라우드 macOS CI 에서 빌드·서명
  (인증서는 여전히 Apple 개발자 계정이 필요하다)

게임 코드는 한 벌로 양쪽을 다 커버한다. 실질 장벽은 엔진이 아니라 Apple 의 서명 파이프라인이다.

## 설계 — 2축

프로젝트 룰(design-principles)의 핵심은 **즉각 조작축 × 누적 관리축**이고, 두 축이 서로를 압박해야 한다.

- **축1 (조준 정밀도)** — 각도를 읽고 벽 반사(뱅크샷)를 계산해 좁은 틈에 넣는다.
  조준선은 반사까지 그려 주는 축1의 도구다.
- **축2 (꽃가루 게이지)** — **시간이 흐르면 줄어든다.** 마르면 벌집이 한 줄 내려온다.
  터뜨린 만큼 회복되고, 빗나가면 더 깎인다.

두 축이 무는 지점: 조준선을 오래 볼수록 정확해지지만 그동안 꽃가루가 흐른다. 서두르면 게이지는
아끼지만 빗나가 판이 커지고 회복 기회 자체가 줄어든다. **도구의 값을 다른 축으로 치르는 구조**다.

난이도 수식은 `scripts/difficulty.gd` 하나가 유일한 원천이다. 전부 `하한 + 여유 × 감쇠^n` 꼴이다.

## 검증

세 가지를 전부 통과해야 배포한다. 명령은 아래, 결과 요약은 `DEVLOG.md`.

```bash
# 수학적 공정성 — 클리어 불가능 구간이 없음을 증명 (약 15초)
godot --headless --path . --script res://tools/verify_fairness.gd

# 봇 4종 총당전 — 체감 난이도와 축2의 가치를 실측 (시드 30에 약 4분)
godot --headless --path . --script res://tools/bot_sim.gd -- --seeds 30

# 스모크 (기능 + 시각) — 실제 씬을 돌리고 .shots/ 에 5장 캡처
godot --path . -- --smoke

# 대결 통합 테스트 — 실제 Supabase 에 피어를 띄운다. 인원수만큼 동시에 실행할 것
godot --headless --path . -- --vstest --size 2 --tag -t1 --round 10 --name A
godot --headless --path . -- --vstest --size 2 --tag -t1 --round 10 --handicap --name B
```

`--tag` 는 공용 로비와 분리하기 위한 것이다. 빼면 실제 플레이어와 매칭된다.
`--round` 는 승패 판정까지 빨리 가려고 어려운 라운드에서 시작하는 옵션,
`--handicap` 은 한쪽을 일부러 약하게 만들어 **승리 경로**를 검증하기 위한 것이다
(같은 시드에 같은 봇 로직이면 둘이 동시에 죽어서 승패가 안 갈린다).

## 빌드

```bash
# 웹 (Windows 에서 그대로 된다)
godot --headless --path . --export-release "Web" build/web/index.html

# 안드로이드 — Android SDK + JDK + 디버그 keystore 를 편집기 설정에 먼저 잡아야 한다
godot --headless --path . --export-release "Android" build/honey-pop.apk
```

웹 빌드는 wasm 38MB(gzip 9.7MB) + pck 1.3MB(gzip 1.2MB)로 **첫 로딩에 약 11MB** 를 받는다.
Godot 웹 빌드의 고정 비용이라 줄이기 어렵다. 정적 호스팅에 얹으면 되고, `thread_support=false`
라서 COOP/COEP 헤더가 필요 없다.

> Daily Game Project 의 기존 배포 채널(Supabase `games` 테이블 → Render)은 **단일 HTML 문서**를
> 서빙하는 구조라 이 다중 파일 40MB 빌드를 그대로 받지 못한다. 그래서 GitHub Pages 로 낸다.

## 배포 (GitHub Pages)

```bash
gh auth login --hostname github.com --git-protocol https --web   # 최초 1회만
bash tools/deploy-pages.sh --build
```

저장소 생성 · 두 브랜치 push · Pages 활성화까지 스크립트가 한 번에 한다. 구조는:

| 브랜치 | 내용 |
|---|---|
| `main` | 소스. `build/` 는 `.gitignore` 로 빠진다 |
| `gh-pages` | 웹 빌드만 루트에 (Pages 가 서빙) + `.nojekyll` |

`gh-pages` 는 `../hp-pages` 워크트리로 관리한다 — 작업 트리를 오가며 브랜치를 갈아끼우지
않아도 되고, 소스와 산출물이 한 커밋에 섞이지 않는다.

`thread_support=false` 로 빌드했으므로 COOP/COEP 헤더가 필요 없다. 헤더를 못 만지는
GitHub Pages 같은 정적 호스팅에 그대로 올라가는 이유다.

**공개 저장소에 Supabase publishable key 가 들어간다.** 랭킹·플레이 로그용 anon 키라
공개를 전제로 만들어진 값이고(RLS 로 insert/select 만 열려 있다), 기존 데일리 게임들도
HTML 안에 그대로 담아 배포해 왔다. 서비스 키가 아니다.

## 파일

| 경로 | 뭐 하는 놈인가 |
|---|---|
| `scripts/difficulty.gd` | **난이도 수식의 유일한 원천.** 값을 고치면 여기서만 고친다 |
| `scripts/board.gd` | 육각 판 — 순수 연산. 엔진 물리·렌더링 금지 (시뮬이 이걸 그대로 굴린다) |
| `scripts/level.gd` | 판 생성 + 다음 구슬. **공정성 규칙 4가지가 여기 있다** |
| `scripts/session.gd` | 한 판의 규칙 전부. 실제 플레이와 봇 시뮬이 **같은 이 파일**을 굴린다 |
| `scripts/rng.gd` | 시드 난수. 게임플레이 결정에 `randi()` 금지 |
| `scripts/play.gd` | 판 화면 — 그리기 + 입력. 규칙은 하나도 없다. `test_*` 훅은 검증이 쓴다 |
| `scripts/main.gd` | 셸 — 메뉴 / 게임오버 / 대결 UI / `--smoke` / `--vstest` |
| `scripts/versus.gd` | 대결 — 로비 매칭, 팀 배정, 공격 교환, 승패 판정 |
| `scripts/net.gd` | Supabase Realtime raw WebSocket. dot-atelier-godot 의 검증된 이식본 |
| `scripts/theme.gd` | 팔레트 + 구슬·벌 그리기 (명암은 셰이더 없이 원을 겹쳐 만든다) |
| `scripts/game_state.gd` | autoload `Game` — 기록·랭킹·플레이 로그 |
| `scripts/audio.gd` | autoload `Sfx` — 파형 합성. 오디오 에셋 파일 없음 |
| `tools/verify_fairness.gd` | 수학적 공정성 검증. 실패하면 exit 1 |
| `tools/bot_sim.gd` | 봇 4종 총당전. **축2가 장식인지 진짜인지 판정한다** |

## 아직 확인 못 한 것

- **웹 빌드의 터치 조작** — 브라우저에서 엔진 부팅·렌더·콘솔 무에러까지는 확인했지만,
  드래그 조준을 실제로 눌러 보는 검증은 못 했다(작업 환경의 브라우저 페인 제약). 실기기 확인 필요
- **실제 APK 빌드** — 이 PC 에 Android SDK/JDK 가 없다. 프리셋만 작성해 둔 상태
- **iOS** — 위 참고. macOS 가 필요하다
