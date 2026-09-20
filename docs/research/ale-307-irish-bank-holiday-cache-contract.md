# ALE-307 — Irish bank-holiday cache contract

**Research date:** 2026-09-20
**Ticket:** ALE-307 (child of the Wayfinder map "Specify dashboard-owned Discord session notifications")
**Question:** Which Irish public-holiday source should the Discord bot use, and what durable local cache + refresh contract avoids a live dispatch dependency? What does the bot do when a refresh fails?

> Scope: This research is a contract design (source pick + on-disk shape + refresh cadence + failure behaviour) for the **dashboard-owned Discord session-notification** workflow that is moving out of the legacy `alessandrojcm/dhc-discord-bot` Go service into a Phoenix-side `Dhc.Discord` capability. It does not implement the cache; it chooses the contract that the implementer will build.

## TL;DR

- **Source of record for Irish public holidays in this project is the [Workplace Relations Commission (WRC) "Public Holidays" page](https://www.workplacerelations.ie/en/what_you_should_know/public-holidays/), mirrored annually as the [Department of Enterprise, Tourism and Employment CSV on data.gov.ie](https://data.gov.ie/en_GB/dataset/https-www-workplacerelations-ie-en-what_you_should_know-public-holidays-public_hols-html) (CC BY 4.0).** Underneath them, the legislation is [Organisation of Working Time Act 1997 (No. 20/1997), Second Schedule](https://www.irishstatutebook.ie/eli/1997/act/20/schedule/2/enacted/en/html) with [S.I. No. 50/2022](https://www.irishstatutebook.ie/eli/2022/si/50/made/en/html) prescribing Imbolc/St Brigid's Day.
- **OpenHolidays API (`openholidaysapi.org`) is an acceptable convenience source but must not be the authoritative one.** It is a third-party German vendor's aggregator, has historically been silent on corrections, has no SLAs, and the project's bot today already depends on it as a live dispatch dependency (it is fetched on every cold cache miss at the moment of the notification). Its Ireland data is derived from WRC + the 1997 Act + the 2022 Commemoration SI, and a live 2026/2027/2028 sample agrees with WRC, but the API adds a layer of indirection and an opaque data-update window the project does not control.
- **Recommended contract:** a **Phoenix-owned, Ecto-persisted, versioned `IrlPublicHoliday` table** with the **canonical Irish source list baked into a private `Dhc.Discord.IrlBankHolidays` rule module** (the legislative rules are stable and small). The on-disk shape is `(date, name, kind, source_url, source_published_on, snapshot_revision)` keyed by year; refresh is an **Oban `:bank_holidays` queue job** that runs **yearly (1 November of year N−1, then 1 December) and on a daily check (06:00 UTC) for any missing year**, pulling the WRC page, parsing the year-table, and writing through `Dhc.Notifications.create_keyed/3` for human alerts on diff; **a 30-day TTL on the cache plus a hard "fall back to the embedded rule table"** when every refresh path has failed for the current calendar year.
- **Failure behaviour:** the dispatch path **never depends on a network round-trip**. If the cache is empty, the rule module computes the holidays for the current year deterministically (St Patrick's = 17 March, Easter Monday from `Date.add(date, 1)` of Easter Sunday, etc.); if the rule module is in doubt (e.g. a year where the Minister has issued a substitution order under Second Schedule paragraph 2), the bot logs `bank_holiday.unknown_substitution`, posts nothing, and an operator is paged via the existing Sentry path. The bot never silently announces "today is a bank holiday" on a wrong source, and never silently treats a bank holiday as a training day on a missing source.

## 1. The legacy bot's current behaviour (status quo)

The Go service at `repos/github.com/alessandrojcm/dhc-discord-bot/main.go:72-161,163-220,342-400` resolves "is this date an Irish public holiday?" by:

1. Looking up `holidayCache` (in-memory `map[string]Holiday`).
2. On miss, calling `fetchHolidays(year, client)`, which:
   - Reads `data/bank-holidays-<year>.json` if it exists; returns it.
   - Otherwise hits `${OPENHOLIDAYS_API_URL:-https://openholidaysapi.org/PublicHolidays}?countryIsoCode=IE&validFrom=<year>-01-01&validTo=<year>-12-31&languageIsoCode=EN`, decodes the JSON into a slice of `Holiday{StartDate, EndDate, Name[], Nationwide, RegionalScope, TemporalScope, Type, ID}`, writes it to `data/bank-holidays-<year>.json` (`0644`), and primes the in-memory map.
3. `isBankHoliday(date)` returns `(true, Name[0].Text, nil)` if the date is in the cache after that, otherwise `(false, "", nil)`.

The cache shape is **whole-year-per-file**, the freshness contract is **"fetch when empty"**, and the dispatch path **calls the API the first time a year is needed** — i.e. there is a live outbound dependency the moment the bot decides whether to skip tonight's training announcement. The contract under analysis here is exactly this path; the move to Phoenix does not change the question, only who owns the file.

## 2. Authoritative Irish public-holiday sources

### 2.1 Statute — Organisation of Working Time Act 1997, Second Schedule

The Second Schedule to the [Organisation of Working Time Act 1997 (No. 20/1997)](https://www.irishstatutebook.ie/eli/1997/act/20/schedule/2/enacted/en/html) enumerates the nine named days plus the open-ended power "any other day or days prescribed for the purposes of this paragraph". Paragraph 2 gives the Minister a power to substitute days by regulation; paragraph 3 allows an employer, with 14 days' notice, to treat the immediately preceding or following Church holiday as a public holiday in lieu.

This is the legal source of truth. It does **not** enumerate dates — it enumerates **rules**.

### 2.2 The 2022 St Brigid's Day regulation

[S.I. No. 50/2022 — Organisation of Working Time (Covid-19 Commemoration) Regulations 2022](https://www.irishstatutebook.ie/eli/2022/si/50/made/en/html) does two distinct things in one instrument:

- Regulation 3 prescribes **18 March 2022** as a one-off public holiday for Covid-19 commemoration.
- Regulation 4 prescribes **the first Monday in February 2023 and every year thereafter** as a public holiday in celebration of Imbolc/St Brigid's Day; Regulation 5 carves out that if 1 February falls on a Friday, then 1 February itself is the public holiday.

That is the rule that increased the count from 9 to 10 in 2023 and is the only annual exception to a simple weekday-anchor rule (May, June, August, last-Monday-of-October).

### 2.3 WRC — the operational source list

The [Workplace Relations Commission's "Public Holidays" page](https://www.workplacerelations.ie/en/what_you_should_know/public-holidays/) is the page the legislation itself tells employers and employees to read: it states the ten days, the St Brigid's Day rule, and the explicit list of dated holidays **for the current year** (today: 2026). It is updated annually by the WRC under the Department of Enterprise, Tourism and Employment. The current page lists:

> 01 January 2026 · 02 February 2026 · 17 March 2026 · 06 April 2026 · 04 May 2026 · 01 June 2026 · 03 August 2026 · 26 October 2026 · 25 December 2026 · 26 December 2026

This is the only human-maintained list with **dated** bank holidays for the Republic of Ireland.

### 2.4 data.gov.ie — the CSV mirror

The same Department of Enterprise list is published as a CSV dataset on the Irish open-data portal: [Irish Public Holidays — data.gov.ie dataset](https://data.gov.ie/en_GB/dataset/https-www-workplacerelations-ie-en-what_you_should_know-public-holidays-public_hols-html). The metadata record states:

- **Published by:** Department of Enterprise, Tourism and Employment
- **License:** Creative Commons Attribution 4.0
- **Update frequency:** Annual
- **Date released:** 2025-01-01
- **Date updated:** 2025-01-01
- **Period of time covered (begin/end):** 2025-01-01 / 2025-12-31
- **Geographic coverage:** National

This is the closest thing to an official machine-readable list. The CSV is one resource, scoped to a single year; for multi-year cache coverage the bot must fetch each year separately (or aggregate).

### 2.5 Citizens Information — a secondary aggregator

[Citizens Information's public holidays page](https://www.citizensinformation.ie/en/employment/employment-rights-and-conditions/leave-and-holidays/public-holidays/) reproduces the same list and shows 2026 and 2027 dated holidays side-by-side. It is **not** the source of record; it derives from the WRC page and the SI, and its value is that it publishes next-year dates earlier than the WRC. It is suitable as a cross-check but not as the primary ingest.

## 3. The OpenHolidays API

[OpenHolidays API](https://www.openholidaysapi.org/en/) is an open-data REST service maintained by STÜBER SYSTEMS GmbH ([openpotato/openholidaysapi](https://github.com/openpotato/openholidaysapi), license: AGPL-3.0) with the raw data kept in [openpotato/openholidaysapi.data](https://github.com/openpotato/openholidaysapi.data) (license: ODbL v1.0).

### 3.1 What it is

- A vendor-hosted aggregator. The README on `openholidaysapi` states the service is built with .NET 10 + PostgreSQL 17 + EF Core + ASP.NET; there is no uptime SLA, no SLA at all, no auth.
- The data layer (CSV in `openpotato/openholidaysapi.data`) is an aggregator per country. For Ireland the listed upstream sources on the [Europe sources page](https://www.openholidaysapi.org/en/sources-europe/) are:
  - **Workplace Relations Commission: Public Holidays**
  - **Organisation of Working Time Act, 1997**
  - **Government agrees Covid Recognition Payment and New Public Holiday** (news article)
- Coverage from 2020 onward (per the `openholidaysapi.data` README).
- Output is JSON or iCal; the relevant Ireland endpoint returns one object per holiday with `startDate`, `endDate`, `type=Public`, `name[{language, text}]`, `regionalScope`, `temporalScope`, `nationwide`.

### 3.2 Live sample (2026–2028)

A live `GET https://openholidaysapi.org/PublicHolidays?countryIsoCode=IE&languageIsoCode=EN&validFrom=2026-01-01&validTo=2028-12-31` returned all ten 2026 holidays, all ten 2027 holidays, and the 2028 set started (truncated at 2028-02-07 St Brigid's Day). The 2026 list matches WRC and Citizens Information exactly; the 2027 list matches Citizens Information exactly; the 2028 list extrapolates from the 1997 Act rules.

### 3.3 What it is not

- **Not the source of record.** It is a downstream aggregator. The license on the API output inherits ODbL from the database and the AGPL-3.0 on the web service, which is fine to use but requires attribution and a share-alike for any *derivative database* the project publishes; a private internal cache used at runtime by the bot is not a "conveyed" derivative database under ODbL Section 1.0, so the practical implication is just attribution, not relicensing.
- **Not historically stable.** The [change log](https://www.openholidaysapi.org/en/change-log-data/) shows "breaking change" renames of CSV columns (`Quality` → `Status`, addition of `RegionalScope`/`TemporalScope`), additions of countries, error corrections, and country additions throughout 2023–2026. The service was added in January 2023 alongside Ireland. For Ireland there is no published "last updated for Ireland" timestamp; the change log shows Spain, Italy, Germany, France, etc. but does not surface per-country update recency.
- **Not SLA-backed.** No terms of service link on the homepage; the project is described as a "small Open Data project". The project does have an Issue Tracker but the repo has 14 open issues and 64 stars at last fetch.
- **Not transparent about correction provenance.** The change log gives summaries but not "row X was wrong on date Y because of source Z"; corrections are not attributable. WRC, by contrast, shows the dated list on a single authoritative page.

### 3.4 Why the current Go bot's pattern is fragile

Three properties compound:

1. The cache is `data/bank-holidays-<year>.json` written by the *same* process that *reads* it. There is no signed origin — a malformed upstream response silently replaces the cache with a 200-OK empty array and the bot happily announces every training night for the rest of the year.
2. There is no TTL. A file written in 2023 is still consulted in 2026; the project has no diff.
3. The dispatch path calls the API on miss. A network blip in the middle of a notification run produces `error fetching holidays: ...` and the bot silently treats the day as not-a-bank-holiday, which is the **wrong direction** — better to false-positive and skip training than to false-negative and announce a non-existent session.

## 4. Comparison

| Axis | OWT Act 1997 + S.I. 50/2022 (statute) | WRC page | data.gov.ie CSV | Citizens Information | OpenHolidays API |
|------|---------------------------------------|----------|------------------|---------------------|-------------------|
| Authority | Primary (legislation) | Operational primary | Operational primary, machine-readable | Secondary aggregator | Tertiary aggregator |
| Machine-readable | No (statute text) | No (HTML) | Yes (CSV, annual) | No (HTML) | Yes (JSON / iCal) |
| Coverage horizon | Indefinite (rules) | Current year only | One year per file | Current + next year | 2020 → rolling |
| Update cadence | Per SI (rare) | Annual (early Jan) | Annual | Annual | Ad-hoc, undocumented for IE |
| Correction visibility | Official Journal | Page revision history | data.gov.ie revision history | Page revision history | Aggregator change log (per-country entries not surfaced) |
| License | Crown copyright, free to reproduce with attribution | WRC / DETE, fair use | **CC BY 4.0** | Citizens Information Board | **ODbL v1.0 (database) / AGPL-3.0 (service)** |
| Uptime / SLA | Permanent | Permanent | Permanent | Permanent | None published |
| Stable field shape | N/A (rules) | N/A (HTML) | Year-stable but column-unverified across years | N/A | **No** — columns renamed 2024-11 (`Status`); breaking changes logged |
| Provenance to source | Direct | Direct | Direct (DETE-published) | Derived | Two-step aggregator |
| Attribution cost | Low (statute citation) | Low (URL) | Low (URL + agency name) | Low (URL) | Medium (must cite project + sources) |

## 5. Recommended contract

The Wayfinder ticket's framing — "dashboard-owned Discord session notifications" — implies the bot is being absorbed into the Phoenix app. The cache should therefore be **a Phoenix-side concern**, not a sidecar JSON file written by a Go process. The recommended shape is:

### 5.1 Source order

A new private module `Dhc.Discord.IrlBankHolidays` (path: `apps/phoenix/lib/dhc/discord/irl_bank_holidays.ex`) encodes the legislative rules directly:

- Fixed dates: 1 January, 17 March, 25 December, 26 December.
- First Monday in February, with the Friday-1-February exception (from S.I. 50/2022 Reg. 4–5).
- Easter Monday = `Date.add(easter_sunday(year), 1)` (use `:calendar` Easter computation; verify by cross-check with WRC for 2026 and 2027).
- First Monday in May, first Monday in June, first Monday in August, last Monday in October.

This rule module is **always consulted first**, regardless of cache state, because the rules are stable and self-contained. The cache exists for one purpose only: to record **human-verified, dated overrides** (e.g. a Minister-issued substitution order under Second Schedule paragraph 2; the 18 March 2022 one-off) and the **attribution trail** so that downstream readers can see "this date came from WRC's 2026-01 page, not from the rules".

### 5.2 Persistence shape

A new Ecto schema `IrlPublicHoliday` under the existing `Dhc.Discord` boundary:

| Column | Type | Notes |
|--------|------|-------|
| `date` | `date`, primary key | Ireland local date (Europe/Dublin), no time |
| `name` | `string` | English, as published by WRC |
| `kind` | `:public \| :substitution \| :one_off` | Distinguishes rule-derived from SI-derived from one-off |
| `source_url` | `string` | The WRC or data.gov.ie URL the row was last confirmed against |
| `source_published_on` | `date` | The "updated" date on the source at refresh time |
| `snapshot_revision` | `string` | Hash of `(source_url, source_published_on, sorted rows)` |
| `inserted_at` / `updated_at` | `utc_datetime_usec` | Standard |

Year coverage: every year from **current − 1 to current + 3** (4 future years is enough for a bot that announces training a week in advance; anything further is the rule module's job).

### 5.3 Refresh contract

- **Yearly refresh:** an Oban cron job on the `:bank_holidays` queue, schedule **1 November YYYY-1** (the WRC publishes next-year dates around this time, sometimes earlier). Idempotent: writes through `Dhc.Discord.IrlBankHolidays.refresh/1`, which fetches the WRC page, parses the dated list, upserts each row, computes a `snapshot_revision`, and emits `Dhc.Notifications.create_keyed/3` with key `irl_bank_holiday.refresh.<year>` and a payload `{added, removed, changed, source_url, source_published_on}` so the next reader has a paper trail.
- **Daily check:** a lighter cron job at **06:00 UTC daily** that, for the current year, fetches the WRC page once more and compares `snapshot_revision`; if it changed, the same keyed notification fires. This is the only outbound HTTP the cache depends on, and it is on a queue that is retried via the existing Oban retry policy.
- **Bootstrap:** on first deploy the job is enqueued once via `mix` task; missing years are backfilled up to the rule-module horizon.

### 5.4 Failure behaviour

The dispatch path **never** calls a third-party API synchronously. The rule:

1. **Always answer from the rule module first.** The rule module is a pure function of `(year, date)` — no IO, no network, deterministic. A bot that only ever knew the rules would still skip every St Patrick's Day and every Christmas correctly.
2. **Prefer the persisted cache row** if it exists and matches the rule output. (Both sources must agree. If they disagree, the cache row wins for that date, but a `bank_holiday.source_mismatch` Sentry event fires.)
3. **If the persisted cache row is missing for the current year and the rule module is confident**, use the rule module's answer and log `bank_holiday.derived_from_rule`.
4. **If the rule module returns a date that the persisted cache row contradicts for a year where `kind = :substitution` or `:one_off`**, trust the cache row (the only path that knows about SIs).
5. **If the rule module is in doubt** (e.g. Easter Monday in a year where the Minister has issued a substitution order that we haven't ingested), log `bank_holiday.unknown_substitution`, post **nothing**, and the Sentry path pages an operator. **The bot never silently treats a date as a non-bank-holiday when it might be one.**
6. **Network failure to WRC** is a refresh failure, not a dispatch failure. The queue retries; the dispatch path runs as usual on the existing rows or the rule module. After 30 days of failed refresh, `bank_holiday.refresh_stale` fires in Sentry so the operator knows the audit trail is going cold.

The single most important property: **no outbound HTTP on the hot path**. The current Go bot fails closed (treats an unreachable API as "not a bank holiday" and posts the training announcement); the new contract fails closed the other way (treats an unreachable source as "don't know, ask a human").

### 5.5 What goes away

- The Go process's `data/bank-holidays-<year>.json` files: no longer written. The legacy bot's `fetchHolidays` and `isBankHoliday` are replaced by `Dhc.Discord.IrlBankHolidays.is_public_holiday/2` and a single Ecto read.
- `OPENHOLIDAYS_API_URL` env var: dropped.
- The `Holiday{Name, ID, EndDate, RegionalScope, TemporalScope, Type, Nationwide}` struct: dropped in favour of the leaner Ecto schema (we never used `regionalScope` / `temporalScope` / `ID` for anything).

### 5.6 What stays

- The in-memory memoisation pattern (`@ holidays_by_date`) inside the Phoenix process, just hot-rebuilt from Ecto on app start and on `IrlPublicHoliday` row changes via the existing `Realtime`/PubSub mechanism. Same algorithmic shape, same testability.

## 6. Open follow-ups (out of scope for ALE-307)

- Whether the dashboard surfaces the cache to the user (e.g. "the bot will skip training on these dates") is a separate ticket.
- Northern Ireland bank holidays are deliberately out of scope — the DHC bot is for a Republic-of-Ireland club and uses `Europe/Dublin`; a future feature flag for NI is a one-row addition to `IrlPublicHoliday`, not a contract change.
- The `Dhc.Discord.IrlBankHolidays` rule module's Easter computation should be backed by a property test that round-trips against the WRC list for 2018–2030 once the rule module is implemented.

## Sources

- [Organisation of Working Time Act 1997, Second Schedule](https://www.irishstatutebook.ie/eli/1997/act/20/schedule/2/enacted/en/html) — primary legislation
- [S.I. No. 50/2022 — Organisation of Working Time (Covid-19 Commemoration) Regulations 2022](https://www.irishstatutebook.ie/eli/2022/si/50/made/en/html) — St Brigid's Day rule
- [Workplace Relations Commission: Public Holidays](https://www.workplacerelations.ie/en/what_you_should_know/public-holidays/) — operational primary source for dated holidays
- [Irish Public Holidays — data.gov.ie dataset](https://data.gov.ie/en_GB/dataset/https-www-workplacerelations-ie-en-what_you_should_know-public-holidays-public_hols-html) — DETE-published CSV, CC BY 4.0
- [Citizens Information: Public holidays](https://www.citizensinformation.ie/en/employment/employment-rights-and-conditions/leave-and-holidays/public-holidays/) — secondary aggregator
- [OpenHolidays API home](https://www.openholidaysapi.org/en/) — third-party aggregator (STÜBER SYSTEMS)
- [OpenHolidays API data change log](https://www.openholidaysapi.org/en/change-log-data/) — correction / breaking-change history
- [OpenHolidays API Europe sources](https://www.openholidaysapi.org/en/sources-europe/) — Ireland upstream citation (WRC, 1997 Act, gov.ie press release)
- [openpotato/openholidaysapi](https://github.com/openpotato/openholidaysapi) — service source (AGPL-3.0)
- [openpotato/openholidaysapi.data](https://github.com/openpotato/openholidaysapi.data) — data source (ODbL v1.0)
- [Live sample: `GET /PublicHolidays?countryIsoCode=IE&languageIsoCode=EN&validFrom=2026-01-01&validTo=2028-12-31`](https://openholidaysapi.org/PublicHolidays?countryIsoCode=IE&languageIsoCode=EN&validFrom=2026-01-01&validTo=2028-12-31) — verified 2026 list matches WRC
- Legacy code: `repos/github.com/alessandrojcm/dhc-discord-bot/main.go:72-161,163-220,342-400` — current live-fetch-on-miss pattern that this contract replaces
