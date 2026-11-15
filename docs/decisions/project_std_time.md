# 표준 모듈 `time` (2026-11-15)

## 배경

스크립트가 시각을 다룰 길이 `os.nanoTime()`(정수 ns)과 `os.FileInfo`의 `mtime_sec` · `mtime_nsec` 두 칸뿐이다. 요구는 셋이다.

- 파일 시각 비교: 어느 파일이 더 새로운지, 얼마나 지났는지.
- 기록의 날짜 계산: 로그의 타임스탬프를 읽고, 날짜를 더하고 빼고, 다시 쓴다.
- 시간대는 UTC와 고정 오프셋부터. 오프셋은 분 단위가 돼야 한다(`+05:30` · `+05:45` · `-03:30`). IANA 시간대 DB는 이번 범위가 아니다.

구현 전에 Rust · Zig · Nim · Python의 방식과 스펙을 1차 자료로 비교했다(아래). 버전은 2026-11-15 기준이다.

## 비교 검토

### Rust (std 1.100, `jiff` 0.2.45, `chrono` 0.4.45, `time` 0.3.55)

- std는 시계만 준다. `SystemTime`(벽시계, `Ord`, `fs::Metadata::modified()`의 반환형) · `Instant`(단조, 차이만) · `Duration`(부호 없음,
  u64 초 + u32 ns). 달력 · 오프셋 타입은 없다. `SystemTime::duration_since`는 순서가 뒤집히면 `Err`이다(벽시계는 뒤로 갈 수 있다).
- 달력은 크레이트 셋으로 갈린다.
  - `jiff`: `Timestamp`(순간, ns) · `civil::{Date, Time, DateTime}`(시간대 없음) · `tz::Offset` · `Zoned`(순간 + 시간대) ·
    `Span`(단위별 필드) · `SignedDuration`(96비트 ns). 연도 -9999..9999. `Timestamp`의 범위는 양끝을 하루 남짓 줄여
    (`-009999-01-02T01:59:59Z` ~ `9999-12-30T22:00:00.999999999Z`) 어떤 오프셋을 붙여도 연도가 범위 안이다.
  - `chrono`: `DateTime<Tz>`(`Utc` · `FixedOffset` · `Local`)와 `Naive*`, `TimeDelta`(하루 = 24시간), `Months` · `Days`.
  - `time`: `OffsetDateTime` · `UtcDateTime` · `PlainDateTime`(구 `PrimitiveDateTime`) · `UtcOffset` · `SignedDuration`. 월 덧셈이 없다.
- 고정 오프셋: 셋 다 초 해상도. 범위는 jiff · time ±25:59:59, chrono ±23:59:59. 그런데 RFC 3339가 초 단위 오프셋을 적지 못해
  chrono는 파싱에서 거부하고, time은 포맷에서 오류를 내고, jiff는 분으로 반올림해 쓴다.
- 산술: 월 · 년 덧셈은 jiff · chrono가 말일로 clamp(03-31 + 1개월 = 04-30). `+`는 범위를 넘으면 panic, `checked_add`는 실패 값.
  날짜의 차이는 jiff `Date::until`이 일수, chrono · time은 duration.
- RFC 3339 파싱: 구분자 `T` · `t` · 공백, `Z` · `z`. 숫자 오프셋은 chrono · time이 `+HH:MM`만, jiff가 `+HH` · `+HHMM` · `+HH:MM`도.
  소수 초는 9자리, 넘는 자리는 버림. `:60`은 jiff가 59로 clamp, time은 59.999999999, chrono는 윤초 표현으로 보존. `-00:00`은 셋 다 0.
  jiff의 `Timestamp` 파싱은 오프셋이 없으면 오류다.
- 형식 문자열: jiff · chrono가 strftime(`%Y %m %d %H %M %S %f %z %:z %j %a %b %F %T %s` ...), time은 `[year]-[month]` 꼴 자체 문법.
- 윤초: std · jiff · time은 세지 않는다. 오류: jiff는 문구를 담은 `Error` 하나, chrono는 주로 `Option`, time은 종류별 타입.
- 저자가 적은 교훈(jiff 설계 문서): 순간을 `Instant`라 부르지 않는다(std의 단조 `Instant`와 헷갈린다). 윤초는 쓰임에 비해 API가
  복잡해져 뺐다. 실패는 `Option`이 아니라 이유를 말하는 `Result`. `Span`에 `==`가 없다(`120분`과 `2시간`).

### Zig 0.17.1

- std에 datetime이 없다. 제안 #8396은 받아들여지지 않았고 구현 PR #19549는 "third party date/time package로 유지하라"로 닫혔다.
- 0.16에서 시계가 `std.Io`로 옮겨졌다. `Io.Clock`(`real` · `awake` · `boot` ...), `Io.Timestamp` · `Io.Duration`은 둘 다 `i96` ns.
  `real`은 윤초를 무시하는 Unix time. 파일 시각은 `Io.File.Stat.mtime: Io.Timestamp`라 비교가 정수 비교로 끝난다.
- `std.time.epoch`는 초 → 연 · 월 · 일 분해만(연 단위 선형 루프, 1970 이전 불가, 역변환 · 파싱 · 포맷 · 오프셋 없음).
  `std.tz`는 TZif 파서만 있고 조회 함수가 없다.
- 패키지: `zeit`(`Instant` i128 ns + 시간대, RFC 3339 · strftime · Go 레이아웃, 월 연산 없음), `zdt`(단일 `Datetime`, 연도 0..9999,
  `RelativeDelta`의 월 덧셈은 말일 clamp, strftime), `zig-datetime`(오프셋 i16 분), `zul`(UTC 전용, RFC 3339만),
  `clickingbuttons/datetime`(#19549의 후신, RFC 3339만, 월 덧셈은 넘침 이월).
- 고정 오프셋은 대부분 i32 초, 분 단위는 `zig-datetime` 하나. 달력 변환은 Neri-Schneider(`zdt` · `clickingbuttons`) ·
  Ben Joffe(`zeit`) · Hinnant(`chrono-zig`) · musl(`zul`)로 모두 루프 없는 정수 산술이다.
- 시사점: 가져다 쓸 std가 없으니 직접 쓴다. 시계만 Zig 쪽(`Io.Timestamp.now`)에서 받고 달력은 순수 정수 산술이면 된다.

### Nim 2.4 · Nimony

- `std/times`: `Time`(i64 초 + ns) · `DateTime`(필드 + `ref Timezone` + `utcOffset`) · `Duration`(초 + ns, 하루 = 86400초) ·
  `TimeInterval`(달력 단위 필드, 정규화 안 함). 문서가 "월 · 년이 필요 없으면 Duration"을 권한다.
- `utcOffset`은 초 단위에 부호가 UTC 서쪽이 양수다(`+01:00`이 `-3600`). 문서가 형식 문자열과 반대라고 스스로 경고하고,
  Nimony는 이름을 `offsetEast`로 바꿔 동쪽 양수로 뒤집었다("조용한 부호 반전을 막는다").
- 고정 오프셋 시간대가 내장돼 있지 않다(`utc()` · `local()`뿐, `newTimezone`에 클로저 둘을 넘겨 직접 만든다).
- 월 덧셈은 clamp가 아니라 넘침 이월이다(10-31 + 1개월 = 12-01).
- 형식은 자체 패턴(`yyyy-MM-dd'T'HH:mm:sszzz`, 오프셋 `z zz zzz ZZZ`). RFC 3339 전용 함수가 없고, 파싱한 오프셋은 보존되지
  않는다(순간으로 환산한 뒤 인자의 zone, 기본 `local()`로 바뀐다).
- `Month`는 1부터, `WeekDay`는 월요일 0. `getDayOfYear`는 0부터. `getIsoWeekAndYear`. 윤초 없음.
- 시계: `getTime()` → `Time`, `std/monotimes`의 `MonoTime`(차이는 `Duration`). 파일은 `getLastModificationTime` → `Time`, `fileNewer(a, b)`.
- Nimony `lib/std/times`: 최소 구현. `DateTime` 필드 공개, `now()`가 UTC, `$Time`이 `Z`로 출력, 기본 zone이 `utc()`.
  `TimeInterval` · 파싱 · 포맷은 아직 없다. Nim 2의 로컬 기본값을 UTC 기본값으로 바꾼 것이 눈에 띈다.

### Python 3.15

- `datetime`: `date` · `time` · `datetime` · `timedelta` · `timezone`. 연도 1..9999, 해상도 1 µs. 한 타입이 naive와 aware 두 뜻을 가진다:
  섞어 비교하면 `TypeError`, `utcnow()` · `utcfromtimestamp()`는 naive를 돌려줘 로컬 시각으로 오해돼 3.12에서 deprecated.
- `timezone(offset)`: -24시간과 +24시간 사이(양끝 제외). 3.7 전에는 정수 분만 받았다.
- `timedelta`는 일 · 초 · µs로 정규화하고 음수는 일만 음수다(`timedelta(microseconds=-1)`이 `(-1, 86399, 999999)`). 월 산술이 없다.
- `weekday()` 월 0, `isoweekday()` 월 1, `isocalendar()`, `toordinal()`(0001-01-01이 1), `tm_yday` 1..366.
- `fromisoformat`(3.11부터): 구분자 한 글자 아무거나, `Z`, 오프셋 `+HH` · `+HHMM` · `+HH:MM`, 소수점 `.` · `,`, 6자리 넘는 소수는 버림.
  `isoformat()`은 µs가 0이면 소수를 빼고 UTC를 `+00:00`으로 쓴다(`Z`가 아니다).
- `strftime` · `strptime`: `%z`는 `+HHMM` 출력, 파싱은 콜론 꼴과 `Z`도. `%:z`(3.12 · 파싱은 3.15), `%f`는 1~6자리, `%j`, `%G %V %u`.
  연도 없는 `%d` 파싱은 3.15부터 오류.
- 윤초를 지원하지 않는다(초 0..59, `:60`은 오류).
- `time.time()`(float) · `time_ns()`(PEP 564: float은 104일 뒤 ns를 잃는다, i64 ns는 1677~2262년) · `monotonic()`(PEP 418).
  파일은 `st_mtime`(float, 문서가 부정확하다고 경고) · `st_mtime_ns`(int).
- 다시 설계한 쪽 `whenever`: `Instant` · `OffsetDateTime` · `ZonedDateTime` · `PlainDateTime`으로 나눴다. 표준의 문제로 든 것은
  naive · aware 한 타입, 시스템 시간대의 암묵 사용, `timezone`이 진짜 시간대가 아님, `timedelta.seconds` 함정. 윤초는 파싱에서 59로.

### 요약

| | Rust | Zig | Nim | Python |
|---|---|---|---|---|
| std의 범위 | 시계 · `Duration`뿐 | 시계 · epoch 분해뿐 | 전부(`times`) | 전부(`datetime`) |
| 순간 | `SystemTime`, jiff `Timestamp` | `Io.Timestamp`(i96 ns) | `Time`(초 + ns) | `time_ns()` 정수, aware `datetime` |
| 달력 타입 | jiff civil + `Zoned`, chrono `DateTime<Tz>` | 패키지 | `DateTime`(zone 포함) | `datetime`(naive · aware 겸용) |
| 고정 오프셋 | 초, ±24~26시간 | 대부분 초 | 초, 서쪽 양수, 내장 없음 | µs, ±24시간 미만 |
| 기본 시간대 | 없음(명시) | 없음 | 로컬(Nimony는 UTC) | naive(로컬로 읽힘) |
| 월 덧셈 | 말일 clamp | 패키지마다 | 넘침 이월 | 없음 |
| 길이 | 초 + ns, jiff는 `Span`도 | i96 ns | `Duration` + `TimeInterval` | 일 · 초 · µs |
| RFC 3339 | 전용 파서 | 패키지 | 패턴으로 | `fromisoformat` |
| 형식 문자열 | strftime(jiff · chrono) | strftime · Go 꼴 | 자체 패턴 | strftime |
| 윤초 | 없음(파싱에서 clamp) | 없음 | 없음 | 없음(오류) |
| 범위 밖 | panic / `checked_*` | 오류 | 예외 | `OverflowError` |

## 결정

1. 타입은 넷: `Time`(순간) · `DateTime`(순간 + 오프셋) · `Date`(달력 날짜) · `Duration`(길이). naive datetime 타입은 두지 않는다.
   Python의 naive · aware 겸용과 Nim 2의 로컬 기본값이 문서로 남은 함정이고, jiff · whenever · Nimony가 모두 "순간"과 "오프셋이
   붙은 달력 시각"을 가른다. 오프셋 없는 기록(`2026-11-15 10:22:01`)은 읽을 때 오프셋을 정한다(결정 6). 시스템 로컬 시간대는
   쓰지 않는다: 시간대 DB가 범위 밖이고, 암묵적인 로컬은 같은 스크립트가 기계마다 다르게 도는 원인이다.
2. 오프셋은 UTC 동쪽이 양수인 분 단위 `int`다(`+09:00`은 540, `-03:30`은 -210). 범위는 -1439..1439(±23:59, Python · chrono와 같고
   RFC 3339 문법이 적을 수 있는 전부). 초 단위는 두지 않는다: RFC 3339가 적지 못해 Rust 크레이트 셋이 거부 · 오류 · 반올림으로
   갈렸다. 부호는 Nim 2의 서쪽 양수를 따르지 않는다(Nimony가 뒤집은 방향). 따로 타입을 두지 않은 것은 값이 정수 하나이고
   `t.to_offset(540)`이 그대로 읽히기 때문이다. `-00:00`은 0이다.
3. 표현: `Time`과 `Duration`은 초 + ns 두 칸(Nim `Time`, jiff, Rust). i64 ns 하나(Go, PEP 564가 적은 1677~2262년)로는 연도
   1..9999를 담지 못한다. `Date`는 1970-01-01부터의 일수 하나, `DateTime`은 순간 + 오프셋이고 연 · 월 · 일은 물을 때 계산한다.
   그래서 값이 항상 정규형이고 필드 조합이 틀릴 수 없다. 필드는 private이고 접근은 메서드다(Nim 2가 setter를 deprecated한 이유와 같다).
4. 범위: `Date`는 0001-01-01..9999-12-31(Python · zdt). `Time`은 0001-01-02T00:00:00Z..9999-12-30T23:59:59.999999999Z로 양끝
   하루를 줄였다(jiff와 같은 이유: 어떤 오프셋을 붙여도 연도가 범위 안이라 `t.utc()`가 실패하지 않는다). 달력은 proleptic Gregorian.
5. 윤초는 세지 않는다(네 언어 모두). 파싱에서 `:60`은 59로 읽는다(jiff · whenever. Python처럼 거부하면 실제 기록이 걸린다).
6. 파싱: `time.parse(s)`는 RFC 3339이고 오프셋이 없으면 오류다(jiff `Timestamp`). `time.parse(s, offset)`은 오프셋 없는 글을 그
   오프셋으로 읽는다(Go `ParseInLocation`. 글에 오프셋이 있으면 그것이 이긴다). 받는 꼴은 jiff 쪽으로 넓게: 구분자 `T` · `t` · 공백,
   `Z` · `z`, `+HH:MM` · `+HHMM` · `+HH`, 소수점 `.` · `,`(Python logging · log4j가 `,123`), 소수 9자리 넘는 자리는 버림.
   파싱한 오프셋은 `DateTime`에 남는다(Nim처럼 버리지 않는다).
7. 형식 문자열은 strftime의 부분집합(jiff · chrono · Python · zdt · zeit. 모델이 쓰는 코드가 이 꼴이다). Nim 패턴 · Go 레이아웃 ·
   time 크레이트 문법은 받지 않는다. `%f`는 Python대로 6자리, `%3f` · `%6f` · `%9f`는 chrono 꼴. 이름은 영어만(로캘 없음).
   모르는 지정자는 조용히 지나가지 않고 `error.Format`이다. 형식에 오프셋이 없으면 `parse_format`은 UTC로 읽는다(Go · Nimony).
8. 출력: `format()`은 RFC 3339. UTC는 `Z`(jiff · time · Nim. Python의 `+00:00`도 같은 뜻이지만 짧은 쪽), 소수는 0이면 빼고 아니면
   뒤의 0을 뗀 만큼(jiff).
9. 산술: `Time ± Duration`, `Time - Time` → `Duration`, 비교 연산자. `Duration`의 하루는 86400초다. 달력 산술은 `add_days` ·
   `add_months` · `add_years`(`Date`와 `DateTime`)이고 월 · 년은 말일로 clamp한다(jiff · chrono · zdt. Nim의 넘침 이월은 10-31 + 1개월이
   12-01이 돼 "다음 달"을 건너뛴다). `Date - Date`는 일수 `int`(jiff `until`의 기본 단위). `Span` · `TimeInterval` 같은 단위별 길이
   타입은 두지 않는다. 고정 오프셋에서는 하루가 늘 24시간이라 `add_days`와 `+ days(n)`이 같다.
10. 범위를 넘으면: 연산자는 panic(Rust `+`), 이름 있는 메서드(`add` · `add_days` · `to_offset` ...)와 생성 함수는 `error.Range`
    (Rust `checked_add`). Cyber의 `int`는 넘치면 조용히 돌아가므로 모듈 안에서 곱셈 전에 한도를 본다.
11. 오류 값은 셋: `error.Syntax`(글이 형식과 다름) · `error.Range`(값이 범위 밖: 13월, 2월 30일, 오프셋 1500) · `error.Format`(형식
    문자열이 틀림). 위치와 문구는 `json` · `regex`처럼 `time.Diag{msg, pos}`.
12. `DateTime`에는 순서 연산자를 두지 않는다. `==`는 구조 비교라(연산자 오버로드 대상이 아니다) 순간이 같아도 오프셋이 다르면
    다르다. `<`만 순간으로 비교하면 `a <= b`이고 `b <= a`인데 `a != b`가 된다. 순서는 `a.time() < b.time()`으로 쓴다.
13. 시계: `time.now()` → `Time`(벽시계), `time.monotonic()` → `Duration`(단조, 기준점 없음, 차이만). Rust · Nim · Python · Zig가 모두
    둘을 가른다. 벽시계는 뒤로 갈 수 있으므로 걸린 시간은 `monotonic()`으로 잰다. Zig 바인딩 `real_ns_` · `mono_ns_`
    (`Io.Timestamp.now(io, .real | .awake)`)만 네이티브고 나머지는 순수 Cyber다. 달력 계산은 문자열 하나에 수십 번의 정수 연산이라
    `regex` · `peg`처럼 Zig로 옮길 이유가 없다.
14. 파일 시각: `os.FileInfo`에 `mtime()` · `atime()` · `ctime()` → `!time.Time`(Rust `modified()`, Nim `getLastModificationTime`).
    정수 칸(`mtime_sec` · `mtime_nsec`)은 그대로 둔다. 범위 밖의 값이면 `error.Range`.
15. 요일은 enum `Weekday`(월요일이 0: Nim · Python `weekday()`), `iso_weekday()`는 1..7. 월 · 일 · 연중 일은 1부터(Nim의 0부터 `yearday`를
    따르지 않는다). ISO 주는 `iso_week()` → `IsoWeek{year, week}`.
16. 달력 변환은 Howard Hinnant의 `days_from_civil` · `civil_from_days`(루프 없는 정수 산술, era 400년). Neri-Schneider가 더 빠르지만
    VM에서는 차이가 없고 Hinnant 쪽이 검증하기 쉽다. Zig std의 연 단위 루프는 따르지 않는다.
17. 받지 않기로 한 것: IANA 시간대와 DST(다음 단계. 그때 `DateTime`에 zone을 더하는 길은 열려 있다: 오프셋은 순간에서 구한 값으로
    남는다), 로컬 시간대, 윤초, 로캘, ISO 8601의 주 날짜 · 서수 날짜 · 기간(`P1D`) 파싱, 2자리 연도의 자유 해석(`%y`는 POSIX 규칙).

## API

```cy
use time

-- 시계
time.now()                          --> Time
time.monotonic()                    --> Duration        차이만 뜻이 있다

-- Time: 순간
time.unix(sec)  time.unix(sec, nsec)  time.unix_millis(ms)      --> !Time
t.unix()  t.unix_millis()  t.subsec_nanos()                     --> int
t + d  t - d                        --> Time            범위를 넘으면 panic
t - u                               --> Duration
t < u  t <= u  t > u  t >= u  t == u
t.add(d)                            --> !Time
t.utc()                             --> DateTime
t.to_offset(540)                    --> !DateTime
t.format()                          --> str             2026-11-15T01:22:03.5Z
t.format('%Y-%m-%d')                --> !str            UTC로

-- DateTime: 순간 + 오프셋
time.datetime(y, mo, d, h, mi, s)                 --> !DateTime   UTC
time.datetime(y, mo, d, h, mi, s, ns, offset)     --> !DateTime
time.parse(s)  time.parse(s, offset)              --> !DateTime   RFC 3339
time.parse_format(s, fmt)  time.parse_format(s, fmt, offset)      --> !DateTime
dt.year() month() day() hour() minute() second() nanosecond() offset()   --> int
dt.weekday()                        --> Weekday
dt.day_of_year()                    --> int
dt.date()                           --> Date
dt.time()                           --> Time
dt.utc()                            --> DateTime
dt.to_offset(m)                     --> !DateTime       같은 순간, 다른 오프셋
dt.replace_offset(m)                --> !DateTime       같은 시계 값, 다른 순간
dt + d  dt - d                      --> DateTime
dt.add(d)  dt.add_days(n)  dt.add_months(n)  dt.add_years(n)   --> !DateTime
dt.format()                         --> str             2026-11-15T10:22:03+09:00
dt.format(fmt)                      --> !str

-- Date
time.date(y, m, d)                  --> !Date
time.parse_date(s)                  --> !Date           YYYY-MM-DD
d.year() month() day() day_of_year() iso_weekday()     --> int
d.weekday()                         --> Weekday
d.iso_week()                        --> IsoWeek{year, week}
d.add_days(n)  d.add_months(n)  d.add_years(n)         --> !Date
d - e                               --> int             일수
d < e ...
d.at(h, mi, s)  d.at(h, mi, s, ns, offset)             --> !DateTime
d.format()  d.format(fmt)           --> str  !str

-- Duration
time.nanos(n) micros(n) millis(n) seconds(n) minutes(n) hours(n) days(n)   --> Duration
d.secs()  d.millis()  d.subsec_nanos()                 --> int      0 쪽으로 버림
d.to_float()                        --> float           초
d + e  d - e  -d  d * n  d < e ...  d.abs()
d.format()                          --> str             1h2m3.5s

-- 그 밖
time.is_leap_year(y)  time.days_in_month(y, m)
time.parse_offset('+05:30')         --> !int            330
time.format_offset(330)             --> str             +05:30
모든 parse 함수는 마지막 인자로 &time.Diag를 받는 꼴이 있다.
```

형식 지정자:

| | |
|---|---|
| 날짜 | `%Y`(4자리) `%y`(2자리, 69..99는 19xx) `%m` `%d` `%e`(공백 채움) `%j`(연중 일) `%b` `%h` `%B` `%a` `%A` |
| 시각 | `%H` `%I` `%p` `%M` `%S` `%f`(6자리, 파싱은 1~9) `%3f` `%6f` `%9f` |
| 오프셋 | `%z`(`+0900`) `%:z`(`+09:00`). 파싱은 둘 다 `Z` · `+0900` · `+09:00` · `+09` |
| 묶음 | `%F`(`%Y-%m-%d`) `%T`(`%H:%M:%S`) `%R`(`%H:%M`) `%D`(`%m/%d/%y`) |
| 그 밖 | `%s`(Unix 초) `%n` `%t` `%%`. 출력 전용: `%u`(1..7) `%w`(0..6, 일요일 0) `%G` `%V` |

## 구현

- `src/std/time.cy`: 타입 · 달력 변환 · RFC 3339 · strftime 파서와 포매터. `src/std/time.zig`: 시계 둘과 바인딩(`cl_mod_bind_time`).
- 나눗셈은 0 쪽으로 버리므로 음수(1970 이전, 음의 길이)에는 `floor_div`를 쓴다.
- `Duration`은 Python `timedelta`처럼 ns가 늘 0 이상인 정규형이다(-0.5초는 `sec=-1, nsec=500000000`). 그래서 `==`가 구조 비교로 맞다.
- `parse_format`에 연 · 월 · 일이 없으면 1970-01-01, 시각이 없으면 00:00:00이다(syslog의 `Nov 15 10:22:01`을 읽을 수 있게.
  Python 3.15는 연도 없는 날짜를 오류로 바꿨지만 그 기록을 읽을 다른 길이 없다).
- wasm(freestanding)은 호스트의 `hostMilliTimestamp` 하나가 두 시계를 ms 해상도로 준다.

## 검증

- `modules/time.cy`: API · 경계(연도 1 · 9999, 윤년, 1970 이전) · 오류 값과 문구.
- Python `datetime`과 차분 시험(`src/tools/time_fuzz_gen.py` · `time_fuzz_run.cy`): 무작위 순간과 오프셋에서 달력 분해 ·
  요일 · 연중 일 · ISO 주 · `strftime` 출력 · RFC 3339 왕복을 비교한다. 78,000건에서 차이가 없었다(Debug 63,000 · ReleaseSafe 15,000).
- 13단계 검증 통과(wasm32-wasi 포함).

## 작업 중 찾은 결함

- F-154: 괄호 묶음이 식 중간의 왼쪽 피연산자면 뒤의 연산자를 모두 가져갔다(`doy - (153 * mp + 2) / 5 + 1`이 이틀 어긋났다).
  `ea14352a`에서 먼저 고쳤다.

## 둘째 단계: IANA 시간대 (2026-11-15)

첫 단계는 UTC와 고정 오프셋까지였다. 이어서 DST가 있는 시간대를 넣었다. 시간대 DB를 다루는 방식을 다시 1차 자료로 비교했다
(Rust `jiff` · `chrono-tz` · `tz-rs`, Python `zoneinfo` · `whenever`, Zig `std.tz` · `zeit` · `zdt` · `chrono-zig`, Nim `times` ·
`timezones`, 그리고 바이너리 하나로 배포되는 런타임의 기준으로 Go).

### 비교

| | 데이터 | 로컬 시간대 | 겹침 · 건너뜀 | 달력 산술 |
|---|---|---|---|---|
| jiff | `TZDIR` → `/usr/share/zoneinfo` 등. Windows에서만 번들(207 kB) | `TZ`(이름 · 경로 · POSIX 규칙) → `/etc/localtime` 링크. 실패하면 `Etc/Unknown` | `Compatible`(기본) · `Earlier` · `Later` · `Reject` | 일 · 월은 시계 값 유지 뒤 `Compatible`, 시간 이하는 경과 시간 |
| chrono-tz | 빌드 때 컴파일해 내장, 시스템 DB를 읽지 않음 | 없음(`iana-time-zone`이 이름만) | `Single` · `Ambiguous` · `None`(건너뜀은 값 없음) | 결과가 없거나 겹치면 `None` |
| Python `zoneinfo` | `TZPATH` → `tzdata` 패키지(348 kB). Windows는 패키지 필수 | 없음(`astimezone()`은 고정 오프셋) | `fold` 0 · 1, 건너뜀은 오류 없이 앞 규칙으로 | `+ timedelta`가 시계 값 연산(DST 무시) |
| whenever | 위와 같음 | `SYSTEM_TZ` | `compatible`(기본) · `earlier` · `later` · `raise` | 정확 단위는 경과 시간, 달력 단위는 시계 값 |
| Zig `std.tz` | TZif 파서뿐(v1~3, 조회 함수 · POSIX 규칙 파서 없음) | 없음 | 없음 | 없음 |
| zeit · chrono-zig | 시스템 폴더(`TZDIR` 또는 목록), 내장 없음 | `TZ` → `/etc/localtime`, Windows API | 없음 | 없음 |
| zdt | 내장(약 700 kB) 또는 시스템 | `/etc/localtime` | `dst_fold` 없으면 `AmbiguousDatetime`, 건너뜀은 `NonexistentDatetime` | `addRelative`는 시계 값 |
| Nim | std는 `local()`뿐(C `localtime`). `timezones`는 JSON 2.3 MB 내장 | C 라이브러리 | 문서화 안 됨 | 시계 값 |
| Go | 시스템 폴더 → 내장 `time/tzdata`(450 kB, 선택) | `TZ`(이름 · 경로) → `/etc/localtime`, 실패하면 UTC | "둘 중 하나, 어느 쪽인지 보장하지 않음" | `AddDate`는 시계 값 |

- TZif 읽기는 모두 같다: v2 이상이면 64비트 블록만 읽고, 마지막 전이 뒤는 footer의 POSIX TZ 규칙으로 계산하고, 윤초
  레코드는 무시한다. Zig `std.tz`는 조회와 규칙 계산이 없어 가져다 쓸 것이 파서뿐이다.
- 이름 검증: Go는 `..`와 앞의 `/` · `\`를 거부, Python은 정규화 뒤 폴더 밖이면 거부, zdt · chrono-zig는 `[A-Za-z0-9+-_/]`만,
  jiff는 폴더를 미리 훑은 목록에서만 찾는다.
- 값의 동등: jiff `Zoned`와 whenever는 순간만 비교한다(whenever는 `strict_eq`가 따로). Python은 같은 zone 객체인지에 따라 달라진다.

### 결정

18. 데이터는 시스템의 zoneinfo 폴더에서 읽는다: `TZDIR`, 그다음 `/usr/share/zoneinfo` · `/usr/share/lib/zoneinfo` ·
    `/usr/lib/locale/TZ` · `/etc/zoneinfo`(Go · zeit의 목록). DB를 내장하지 않는다: 200~700 kB가 바이너리에 붙고 tzdata는 한 해에
    여러 번 바뀐다. 그래서 Windows와 wasm에는 이름으로 읽을 DB가 없고 `time.zone(name)`이 `error.NotFound`다. 그 자리는
    `time.zone_from_tzif(name, bytes)`(Python `from_file`, tz-rs의 읽기 함수 주입)와 `time.zone_from_posix(rule)`로 메운다.
    `UTC`는 DB 없이도 있다(Go).
19. 이름은 네이티브 쪽에서 검증한다: 글자 · 숫자 · `+ - _`와 `/`만, 빈 조각 · 앞뒤 `/` 없음, 255바이트까지. `.`을 받지 않으므로
    폴더 밖으로 나가지 못한다(zdt · chrono-zig 방식). `time`은 임베딩된 스크립트도 쓰는 기본 모듈이라, 이 모듈이 읽는 파일은
    zoneinfo 폴더 안의 TZif(매직 4바이트 확인, 1 MiB까지)와 `time.local()`의 `/etc/localtime` · `TZ`가 가리키는 파일뿐이다.
20. TZif는 v1(32비트)과 v2 이상(64비트 블록 + footer)을 읽는다. 윤초 레코드는 건너뛴다. 읽을 때 한 번 전체를 검사한다
    (개수와 길이, 전이의 오름차순, 타입 번호, 약어 표의 끝, 오프셋 범위). 틀리면 `error.Syntax`.
21. `Zone`은 파일 바이트를 `str` 하나로 들고 전이를 물을 때 거기서 읽는다(이진 탐색). 배열로 풀지 않은 이유는 `==`다: 슬라이스는
    참조로 비교되고 문자열은 내용으로 비교되므로, 같은 파일을 따로 읽은 두 zone이 같다고 나온다. Python이 "같은 zone"을 객체
    동일성으로 판정해 캐시가 의미를 좌우하는 문제를 피한다. 캐시는 두지 않는다(전역 상태).
22. 오프셋은 분 단위를 유지한다. DB의 초 단위 오프셋(LMT, 대개 1920년 이전. `America/New_York` 1883년 이전 -4:56:02)은
    분으로 반올림한다. 그 시절의 시각은 실제보다 30초까지 어긋난다. jiff도 출력에서는 분으로 반올림한다.
23. `DateTime`이 zone을 품는다(jiff `Zoned`, Go `Location`, Python aware `datetime`). `t.to_zone(z)`가 만든 값은 `add_days` ·
    `add_months` · `add_years`가 시계 값을 유지한 뒤 zone에서 다시 해석하고, `+ Duration` · `add`는 경과 시간을 더한 뒤 그 순간의
    오프셋을 다시 구한다(jiff · whenever와 같은 나눔. Python의 `+ timedelta`가 DST를 무시하는 것은 따르지 않는다).
    `utc()` · `to_offset` · `replace_offset`은 zone을 뗀다.
24. 시계 값 → 순간: 기본은 `compatible`(jiff · whenever · RFC 5545, Python `fold=0`과 같은 결과). 겹치면 앞쪽, 건너뛰면 시계를
    돌리지 않았을 때의 시각(02:30 → 03:30). `Disambiguation`은 jiff의 넷(`compatible` · `earlier` · `later` · `reject`)이고
    `reject`의 오류는 `error.Ambiguous` · `error.Skipped`(zdt · whenever처럼 둘을 가른다). Go처럼 "어느 쪽인지 보장하지 않음"이나
    chrono처럼 건너뜀에 값을 주지 않는 쪽은 따르지 않는다.
25. 로컬 시간대는 `time.local()` → `!Zone`으로 명시해서 얻는다(결정 1의 "암묵적 로컬 없음"은 그대로다). `TZ`가 있으면 그것
    (빈 값은 UTC, 앞의 `:`는 뗌, 절대 경로는 TZif 파일, 아니면 zone 이름, 그것도 아니면 POSIX 규칙), 없으면 `/etc/localtime`
    (링크 대상의 `zoneinfo/` 뒤가 이름). 알 수 없으면 Go처럼 조용히 UTC로 가지 않고 `error.NotFound`다(jiff `try_system`).
    Windows의 레지스트리 → IANA 이름 매핑(CLDR `windowsZones`, chrono-zig는 70 kB 표)은 넣지 않았다.
26. `%Z`는 출력 전용이다: zone의 약어(`KST` · `EDT`), zone이 없으면 `UTC` 또는 오프셋. 약어는 여러 zone이 같이 써서(`CST`)
    파싱하지 않는다. `format()`은 RFC 3339 그대로다(RFC 9557의 `[Asia/Seoul]` 꼬리는 붙이지 않는다).
27. 규칙 계산은 Go `tzset`처럼 그 순간의 해에서 시작 · 끝 시각을 구해 비교한다. `Mm.w.d` · `Jn` · `n`, 시각은 -167..167시간(v3).
    날 없이 DST만 있는 규칙(`EST5EDT`)은 C 라이브러리들처럼 미국 규칙으로 읽는다.

### API(추가)

```cy
time.zone('Asia/Seoul')                 --> !Zone           시스템 DB, 없으면 error.NotFound
time.local()                            --> !Zone
time.zone_from_tzif(name, bytes)        --> !Zone
time.zone_from_posix('EST5EDT,M3.2.0,M11.1.0')   --> !Zone
z.name()  z.offset_at(t)  z.is_dst(t)  z.abbreviation(t)
z.datetime(y, mo, d, h, mi, s)          --> !DateTime       compatible
z.datetime(y, mo, d, h, mi, s, ns, .reject)      --> !DateTime
t.to_zone(z)  dt.to_zone(z)             --> DateTime        같은 순간
dt.replace_zone(z)                      --> !DateTime       같은 시계 값
dt.zone()                               --> ?Zone
d.at(h, mi, s, z)                       --> !DateTime
```

### 검증(추가)

- `modules/time.cy`: POSIX 규칙 zone으로 전이의 경계, 겹침 · 건너뜀의 네 방식, zone 안의 산술, 규칙의 여러 꼴(모든 대상).
- `modules/time_zone.cy`: `src/test/assets/time-zone`의 TZif 넷(tzdata 2026f)을 읽어 Python `zoneinfo`가 같은 파일에서 낸 값과
  비교, 잘린 파일은 `error.Syntax`. `os.read_file`을 쓰므로 `regex_spec.cy`와 같은 조건에서 돈다.
- Python `zoneinfo`와 차분 시험(`src/tools/time_zone_fuzz_gen.py` · `time_zone_fuzz_run.cy`): 시스템 DB의 모든 zone에서 고른
  순간(절반은 전이 근처)의 오프셋 · 약어 · DST와, 시계 값을 `fold` 0 · 1로 읽은 순간을 네 방식과 비교. 40,000건 차이 없음(Debug 28,000 · ReleaseSafe 12,000). 13단계 검증 통과.
- `time.zig`의 이름 검증 단위 테스트는 `lib-test`에서 돈다.

### 작업 중 찾은 결함(추가)

- F-155: `bool` · enum · `error` · raw 정수 필드가 있는 구조체의 `==`가 컴파일 오류였다(core `@eq`). `Zone`에 `bool` 필드를
  두다가 찾았고 먼저 고쳤다.

## 남은 일

- 내장 tzdata(Windows · wasm에서 이름으로 찾기)와 Windows의 로컬 시간대. 크기(200~700 kB)와 갱신 주기를 보고 정한다.
- RFC 9557 꼬리(`[Asia/Seoul]`)의 출력과 파싱, `Date`의 주 날짜 파싱, 기간 표기(`PT1H`).
- 한 전이 앞뒤 하루 안에 전이가 또 있으면 `at_local`이 가까운 쪽 하나만 본다(tzdata 2026f에는 그런 zone이 차분 시험에서
  드러나지 않았다).
