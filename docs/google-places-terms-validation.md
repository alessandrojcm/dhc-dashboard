# Google venue selection: what ALE-439 established

Checked against Google's public documentation on 6 November 2026.

## Confirmed scope and account region

The user reconfirmed ordinary Google Maps venue-name search: search, deliberately
select a result, save the destination, and use it for directions and native
Calendar location. Address-only autofill was rejected as a replacement. This
product choice is settled; provider validation must work within it rather than
reopening the same scope question. The intended billing account is Ireland/EEA.
See the authoritative [venue design](google-maps-venue-design.md).

These confirmations record scope and account region. They do not establish a
licensing exception or authorize implementation, Google provisioning or
production operations.

## Owner decision: Place ID only (ALE-442)

Recorded 11 November 2026. The owner decided how ALE-442 resolves the open
retention question below: **store the Place ID and its provenance only**.

- Saved per selection, in each Workshop domain's own table:
  `destination_place_id`, `destination_provider: google` and an
  application-generated `destination_selected_at` (the command clock). Place
  IDs may be stored indefinitely ([Places policy][policies]). No business
  name, address, credits, raw response or coordinates are stored.
- The form has **one destination input** with Google autocomplete beneath it.
  Choosing a suggestion shows that suggestion's text in the input, with Google
  Maps attribution, for the current form session only; only the Place ID is
  submitted. Google's text and credits are discarded on typing again, clear or
  unmount, and are never submitted, saved, shown to attendees or sent to
  Calendar. A saved place reopens as "selected" without Google text; no fresh
  Details lookup is made for it.
- Text typed without choosing a suggestion (including when Google is
  unconfigured, unavailable or has no match) is saved exactly as written as the
  manual `destination_text`. A saved destination is manual text or a selected
  place, never both, so no Google result is ever copied into stored text.
- Attendees see the short label plus the manual text, or for a selected place
  the label plus "Get directions", whose link is
  `https://www.google.com/maps/dir/?api=1&destination=<label>&destination_place_id=<id>`.
  The link discloses only the label and the ID; it displays no Google content,
  so attendee surfaces carry no Google attribution (an ID-only map link is a
  documented exception; see [Maps URLs][urls]). Calendar gets the manual text,
  else the label.
- Because no Google text or credits are retained, there is nothing to refresh
  or delete beyond the ID itself: replacing or removing the place clears it,
  and the 12-month ID refresh remains a later, review-only operation.

Sections below record the validation as it stood before this decision; where
they call storage of Google text "unresolved", this decision applies instead.

## Short answer

The feature is technically supported: search for a venue, select it, show the
destination, and write its address into Calendar's native `location` field.
Calendar describes that field as "Geographic location of the event as free-form
text." There is no Calendar-specific prohibition identified here. [Calendar API][calendar]

There are two different data flows:

- **Street-address autofill:** Google expressly exempts a selected street address
  that the user could have entered accurately themselves, for that user's
  specific transaction. Keeping the existing staff-written venue label and
  using this address for the workshop describes a different, narrower flow.
- **Venue/business lookup plus Place Details:** the chosen integration returns
  Google business names and addresses. Those fields are not automatically
  covered by the street-address exception. Their durable use remains unvalidated.

Custom licensing has not been shown necessary. The address-only flow is
reference material, not a proposed replacement for the confirmed venue search.

This report does not establish that the feature is prohibited. It also does not
clear ALE-439 or unblock ALE-442: data retention/reuse for the agreed venue
lookup remains to be validated under the applicable EEA terms.
Manual destinations can proceed independently. The agreed
[venue design](google-maps-venue-design.md) is unchanged.

## The specific terms question

Google's [Places policy][policies] distinguishes these cases:

- **Ordinary Places results:** the general terms restrict copying/saving business
  names and addresses and caching content without an express exception. Place
  IDs may be stored indefinitely. A 30-day coordinates exception does not permit
  a 30-day address/name cache. [General terms §3.2.3][terms], [SST A.3/B.14.3][sst]
- **Selected street address:** the policy says the address is not subject to
  Maps Content restrictions when the end user could have supplied it completely
  and accurately without Autocomplete, solely for that user's specific
  transaction. This excludes suggestion lists, other content, and POI/address
  lookups offered by other Maps services. Selecting any business result does not
  automatically make all its returned fields exempt.

Keep the distinction explicit: an address selected as form input may qualify;
a business name/address discovered through Place Details is not automatically
covered. Copying a provider result into a "manual" field does not establish
independent provenance.

Google also documents address/geocode autocomplete excluding businesses. That
is a narrower integration and is not the chosen product scope. The published
street-address exception does not explicitly discuss Calendar attendee copies;
it must not be presented as either a guarantee for venue lookup or a reason to
require the rejected address-only replacement.
[Address-entry guidance][address-entry]

Before implementing Google-derived persistence, establish the permitted
retention/reuse for the exact venue selection/resolution flow. Report a concrete
provider limitation if one is established; do not infer either approval or a
need for a negotiated licence from an unresolved interpretation.

### Which account terms apply?

EEA applicability follows the **Google billing account's address**, not the
club's name, server region or search location. The owner confirmed the intended
billing account is Ireland/EEA. Its project and any negotiated/reseller agreement
have not been inspected; the billing-region question is settled.
[EEA terms][eea-terms], [FAQ][eea-faq]

For an EEA account, the current SST permit address lookup/autocompletion but
limit other non-ID/non-coordinate Places uses to listed categories, and restrict
use "With any Map", including some links. Provider-supplied source links and
ID-only map linking have documented exceptions. Assess these rules only for
content that remains Google Maps Content. [EEA SST B.15][eea-sst],
[permitted uses][eea-uses], [EEA integration guide][eea-guide]

Do not assume an old project avoids EEA terms: the pre-8-July-2025 exception
requires an unmodified integration. The FAQ lists new services, methods and
response fields as material changes. Calendar OAuth is not evidence of an
existing Places integration. The terms pages checked were dated 26 August 2026;
both SST pages, 28 October 2026. These public pages do not establish the club's
accepted agreement.

## Destination data contract

These decisions concern data handling, not a new shared venue database. Each
Workshop domain keeps its own storage and commands.

- **Staff-owned short label:** preserve it separately; do not populate it
  automatically from Google's business name. Keep the Beginners' Workshop
  80-character limit and existing email copy.
- **Independently supplied manual text:** one `destination_text` field, saved
  as typed, displayed to attendees (with a Maps search link) and projected to
  Calendar without a Places dependency. (ALE-442 replaced the earlier
  name/address/manual-link fields.) Omission preserves the destination;
  explicit clear removes it; manual text replaces any selected place.
- **Suggestion text:** display only for the current search with attribution;
  discard when replaced, abandoned or unmounted. No database, persistent draft,
  CDN/service-worker cache, analytics or raw-response fixtures.
- **Selected name/address:** show a transient preview with attribution. Durable
  storage and attendee/Calendar reuse remain unresolved for non-exempt provider
  text. An address that actually meets the selected-address exception is treated
  according to that exception, not automatically as permanently restricted
  Places data. Do not invent a refresh TTL as a substitute for permission.
- **Place ID and provenance:** an ID may be stored indefinitely with
  `provider: google` and an application-generated selection/check timestamp.
  Google recommends refreshing IDs older than 12 months using Details `id`
  only. Clear on destination replacement/removal; obsolete or moved results
  require review, never automatic relocation of a workshop. [Place IDs][ids]
- **Directions URL:** construct a Maps URL from permitted destination text,
  optionally with the selected Place ID. Use `api=1`, `destination`, and optional
  `destination_place_id`; omit origin and encode values. No key is needed.
  Constructing a URL does not exempt restricted text inside it. Do not request
  or retain `googleMapsUri` merely to make a directions link. [Maps URLs][urls]
- **Attribution:** retain required credits alongside any retained non-exempt
  provider data under the permission that allows its retention. Raw responses,
  coordinates, photos, reviews and contact details are not part of the contract.

Calendar receives permitted name/address text, falling back to the existing
label. It has no ordinary structured Place-ID field; a successful text write
does not prove exact Place binding or native navigation quality. Exporting
non-exempt provider text, its retention in guest copies, and attribution remain
part of the unresolved assessment. Do not add description links as a workaround
or rewrite past events. Isolated native-navigation acceptance stays in ALE-445.

## Lookup implementation contract

The technically supported candidate is **Autocomplete (New), then Place Details
(New) on deliberate selection**, through one domain-neutral Phoenix Req/Req.Test
boundary. It does not write workshops. The retention decision above must be
resolved before treating its preview fields as saved destination fields.

1. Suggest: `POST https://places.googleapis.com/v1/places:autocomplete` with
   server-only `X-Goog-Api-Key`. Send `input`, random session token,
   `languageCode: en`, `regionCode: ie`, and `locationBias.circle` centred at
   `53.3498, -6.2603` with radius `30000` metres. Omit geographic restrictions,
   type filters, origin and query predictions. The circle biases toward Dublin
   without excluding other locations. Mask:
   `suggestions.placePrediction.placeId,suggestions.placePrediction.text.text`.
   Return ordered `{placeId, text}` suggestions; none is an empty success.
   [Autocomplete][autocomplete]
2. Resolve: `GET https://places.googleapis.com/v1/places/{encodedPlaceId}` with
   the same session token, `languageCode=en` and mask
   `id,displayName,formattedAddress,attributions`. Map to a closed preview:
   `{provider: google, placeId, name, address, attributions}`. In New,
   `displayName.text` is the business name; `name` is a resource identifier.
   Map credits from `{provider, providerUri}`. Do not parse prediction text into
   authoritative name/address fields or expose raw JSON. [Details][details]
3. Start a fresh UUID v4 per search interaction; end it on selection/resolution
   or abandonment. All calls in a session use the same Google project. Replacing
   a selection starts a new session. Debounce/cancel superseded searches and
   reject stale responses. Never use a workflow credential as the session token.
   [Sessions][sessions]
4. Authenticate/capability-check and bound lookup requests. Return closed
   unavailable/configuration/quota/not-found failures, not provider bodies.
   Manual saving must work for every failure and when Places is unconfigured.
   Return lookup responses with `Cache-Control: no-store`.

Google receives only the venue query/ID, random session token, fixed bias and
language, field mask, key and normal server network metadata. Forward no browser
cookies, client-IP headers, Referer, workshop IDs/details or attendee facts.
Exclude lookup bodies/queries from logs, Sentry and analytics. Attendee links
must disclose only destination information and preserve no-referrer navigation,
especially on credential-bearing Intake pages.

## Attribution and configuration

Display **Google Maps** branding in the suggestions container, selected-result
preview and any attendee surface displaying non-exempt Google data. Show returned
third-party credits too; keep them associated and visible on mobile. Manual
facts must not be falsely attributed to Google. Use the current official
logo/text/accessibility rules, and the application terms/privacy notices required
by the applicable agreement. A link or internal provider marker alone is not
attribution. [Places policy][policies]

Places needs its own billing-enabled project, **Places API (New)** enablement and
restricted server key. Restrict it to that API and the actual public egress IPs;
confirm stable egress before activation. No browser key is needed by this
candidate. A later Maps JavaScript choice needs a separate website-restricted
browser key and a fresh integration decision. Calendar organizer OAuth is
separate. No setup or billing/key changes were performed. [Setup][setup],
[key security][security]

Review current quotas and session pricing before activation: requesting
`displayName` is not an ID-only lookup, and session billing differs from
standalone field-tier pricing. No zero-cost assumption is made.
[Session pricing][pricing]

## Checks for the later autocomplete ticket

- Substitute Google with synthetic Req.Test data. Assert the exact calls/masks,
  session lifecycle, non-exclusive Dublin bias, closed mapping, empty results,
  quota/auth/outage handling and stale-response rejection.
- Test real form submissions through all four workflows, manual fallback,
  replacement/clear/omission, field errors, keyboard/phone behaviour and the
  short-label limit. Test the resolved field permission/retention rules, not an
  assumed blanket right to save provider JSON.
- Check attribution and privacy on selected results and every attendee surface;
  verify no persistent lookup cache or credential-bearing requests/referrers.
- Run the existing substituted Calendar protocol against real source changes:
  native location, preserved event/RSVP identity, normal updates, no-op silence
  and enrichment without false reschedule emails. Live acceptance and production
  operations still require separate authorization.

[calendar]: https://developers.google.com/workspace/calendar/api/v3/reference/events#location
[policies]: https://developers.google.com/maps/documentation/places/web-service/policies
[terms]: https://cloud.google.com/maps-platform/terms
[sst]: https://cloud.google.com/maps-platform/terms/maps-service-terms
[eea-terms]: https://cloud.google.com/terms/maps-platform/eea
[eea-sst]: https://cloud.google.com/terms/maps-platform/eea/maps-service-terms
[eea-faq]: https://developers.google.com/maps/comms/eea/faq
[eea-uses]: https://cloud.google.com/terms/maps-platform/eea-places-api-permitted-uses
[eea-guide]: https://developers.google.com/maps/comms/eea/places
[ids]: https://developers.google.com/maps/documentation/places/web-service/place-id
[urls]: https://developers.google.com/maps/documentation/urls/guide
[autocomplete]: https://developers.google.com/maps/documentation/places/web-service/place-autocomplete
[details]: https://developers.google.com/maps/documentation/places/web-service/place-details
[sessions]: https://developers.google.com/maps/documentation/places/web-service/place-session-tokens
[setup]: https://developers.google.com/maps/documentation/places/web-service/get-api-key
[security]: https://developers.google.com/maps/api-security-best-practices
[pricing]: https://developers.google.com/maps/documentation/places/web-service/session-pricing
[address-entry]: https://developers.google.com/maps/documentation/geocoding/best-practices#respond-to-user-input
