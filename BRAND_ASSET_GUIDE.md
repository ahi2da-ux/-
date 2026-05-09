# 짠테크 브랜드 에셋 가이드

## 앱 이름

- 표시 이름: `짠테크`
- 확장 컨셉: `2030 자산형성`
- 핵심 메시지: `1억 모으기 = 절약 + 저축 + 투자`

## 앱 아이콘 A안: 위치핀 + 원화

### 디자인 스펙

- 배경: `#2D5BFF`
- 중앙 심볼: 흰색 위치핀
- 위치핀 내부 원: `#2D5BFF`
- 원 안 심볼: 흰색 `₩`
- 하단 텍스트: 흰색 `짠테크`
- 폰트 권장: Pretendard ExtraBold 또는 SF Pro Display Heavy
- iOS 모서리 라운드는 시스템이 자동 적용하므로 PNG 자체에는 둥근 마스크를 넣지 않는다.

### SVG 템플릿

아래 SVG를 Figma, Sketch, Pixelmator, Affinity Designer 등에 붙여넣고 `1024x1024 PNG`로 export한다.

```svg
<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="1024" height="1024" fill="#2D5BFF"/>
  <path d="M512 146C359.1 146 235 270.1 235 423C235 625.5 512 842 512 842C512 842 789 625.5 789 423C789 270.1 664.9 146 512 146Z" fill="white"/>
  <circle cx="512" cy="420" r="132" fill="#2D5BFF"/>
  <text x="512" y="470" text-anchor="middle" font-family="Pretendard, SF Pro Display, Apple SD Gothic Neo, sans-serif" font-size="142" font-weight="800" fill="white">₩</text>
  <text x="512" y="930" text-anchor="middle" font-family="Pretendard, SF Pro Display, Apple SD Gothic Neo, sans-serif" font-size="86" font-weight="800" fill="white">짠테크</text>
</svg>
```

### 필요한 PNG 사이즈

| 용도 | 크기 |
|---|---:|
| App Store | `1024x1024` |
| iPhone App 60pt @3x | `180x180` |
| iPhone App 60pt @2x | `120x120` |
| Spotlight 40pt @3x | `120x120` |
| Settings 29pt @3x | `87x87` |
| Spotlight 40pt @2x | `80x80` |
| Notification 20pt @3x | `60x60` |
| Settings 29pt @2x | `58x58` |
| Notification 20pt @2x | `40x40` |

### Xcode 적용 방법

1. Xcode 왼쪽 파일 목록에서 `Assets.xcassets`가 없으면 `File > New > File... > Asset Catalog`로 만든다.
2. Asset Catalog 안에 `AppIcon`을 만든다.
3. 위 크기별 PNG를 각 칸에 드래그 앤 드롭한다.
4. Target 설정의 `App Icons and Launch Screen`에서 App Icon이 `AppIcon`으로 연결되어 있는지 확인한다.

## 스플래시 방향

현재 프로젝트는 `LaunchScreen.storyboard`가 없고 `Info.plist`의 `UILaunchScreen`만 비어 있다.

추후 스플래시를 별도 구현할 때 권장:

- 배경: `#2D5BFF`
- 중앙: 앱 아이콘 심볼 또는 흰색 `짠테크`
- 하단 문구: `2030 자산형성`
- 로직 없이 정적 LaunchScreen만 사용
