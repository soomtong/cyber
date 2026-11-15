# TZif fixtures

`modules/time_zone.cy`가 읽는 시간대 파일이다. IANA Time Zone Database 2026f의 컴파일된 TZif(RFC 9636) 파일을
macOS의 `/usr/share/zoneinfo`에서 그대로 복사했다. tz database는 public domain이다.

| 파일 | zone | 고른 이유 |
|---|---|---|
| `America_New_York.tzif` | `America/New_York` | 전이가 많고 footer 규칙(`EST5EDT,M3.2.0,M11.1.0`)이 있다 |
| `Asia_Seoul.tzif` | `Asia/Seoul` | DST 없는 footer(`KST-9`), `+08:30` 시절과 1987~1988년 DST |
| `Australia_Lord_Howe.tzif` | `Australia/Lord_Howe` | 30분 DST, 남반구, 숫자 약어 |
| `Europe_Dublin.tzif` | `Europe/Dublin` | 분 단위가 아닌 옛 오프셋(DMT -0:25:21) |

갱신: 파일을 다시 복사하고, 기대값은 같은 파일을 읽는 Python `zoneinfo`로 다시 뽑는다
(`PYTHONTZPATH`를 fixture를 `Area/Location` 꼴로 놓은 폴더로 준다). `Asia_Seoul.tzif`의 길이(617)를 보는 검사도 고친다.
