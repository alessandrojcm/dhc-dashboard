# Workshop destinations: Google Places validation (ALE-439)

Validated against public Google documentation on 6 November 2026 for
[ALE-439](https://linear.app/alessandrojcm/issue/ALE-439/venues-validate-places-terms-and-permitted-destination-data).
The [confirmed venue design](google-maps-venue-design.md) and
[ALE-438](https://linear.app/alessandrojcm/issue/ALE-438/spec-workshop-venue-autocomplete-and-directions)
remain the product scope. This document authorizes no implementation, Google
provisioning, billing/key changes, live acceptance, activation or backfill.

## Decision and gate status

**Google-derived saved destinations and Calendar export remain gated.** Public
terms support retaining Place IDs and fetching fresh details for permitted
in-app use. They do not establish permission for the agreed durable
name/address-to-Calendar workflow. The relevant billing account and agreement
have not been inspected. This is an engineering compliance decision on public
evidence, not legal advice or a determination of the club's actual contract.

The manual path remains supported independently: a required staff-owned short
label, optional independently supplied destination name/address and optional
validated manual Maps link. Those facts may be saved in each source domain and
projected into native Calendar `location` through the existing protocol.
Do not copy a Places result into the manual path and rename its provenance.
No manually entered destination needs a provider identity or a Places lookup.

[ALE-442](https://linear.app/alessandrojcm/issue/ALE-442/venues-shared-google-autocomplete-across-workshop-forms)
must not ship its Google path on the strength of this report. Keep the agreed
native Calendar location goal; neither a description-link workaround, an
ID-only destination nor manual retyping of provider text silently replaces it.

## Applicable terms: verified rules and missing account facts

| Public evidence                                                                                                                                                                                                                                                                 | Consequence for this integration                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Both general and EEA Maps terms select EEA applicability by **billing account address**, with an exception for a pre-8-July-2025 project integration remaining unmodified. Ireland is in the FAQ's EEA list.                                                                    | Club geography, server region and attendee location do not establish the account's terms. New Places functionality cannot inherit an exception merely because Calendar OAuth already exists. [General terms][terms], [EEA terms][eea-terms], [FAQ][eea-faq].                                                                                                                                   |
| The FAQ describes additional services, methods and response fields as material modifications, and treats integrations in a project as having the same state. It warns that it is a point-in-time reference.                                                                     | Read the current agreement first. Do not enable Places in an existing project or accept new terms to test this assumption. [FAQ][eea-faq].                                                                                                                                                                                                                                                     |
| General terms §3.2.3(a)-(b) and EEA terms §3.3.2(a)-(b) prohibit export outside the Services, copying/saving business names and addresses, and caching unless expressly permitted.                                                                                              | Saving a selected venue is still storage. Refreshing every 30 days does not legalize fields without a caching exception. [General terms][terms], [EEA terms][eea-terms].                                                                                                                                                                                                                       |
| Both Service Specific Terms A.3 allow Google-ID caching. Places B.14.3 (general) / B.15.4 (EEA) permit latitude/longitude caching for up to 30 consecutive days. The Places policy explicitly allows indefinite Place-ID storage.                                               | The identifier exception does not extend to names, addresses, URLs or an entire result. Coordinates are outside this feature and its lookup mask. [General SST][sst], [EEA SST][eea-sst], [Places policy][policies].                                                                                                                                                                           |
| EEA SST B.15.1 prohibits non-ID/non-coordinate Places content "With any Map"; its definition includes linking, except a link to the content's source map. B.15.2 limits that content to enumerated permitted uses.                                                              | A no-map suggestions UI can support address autocomplete under permitted use (1). That does not establish ongoing venue display, generated directions links or Calendar exports. Uses (2), (4), (6) and (8) have specific store, productivity, financial-transaction or social-platform contexts; none is assumed to cover this club workflow. [EEA SST][eea-sst], [permitted uses][eea-uses]. |
| The EEA integration guide permits provider-supplied source links and ID/coordinate-only map linking. Places UI Kit is exempt from the two EEA restrictions above.                                                                                                               | An arbitrary generated link containing Places text is not automatically the source-link exception. UI Kit changes display integration, not the default storage/export rules, so it does not solve durable Calendar locations. No switch to UI Kit is approved here. [EEA guide][eea-guide], [EEA SST][eea-sst].                                                                                |
| The street-address Autocomplete exception applies only when the end user could otherwise have supplied the address completely/accurately, solely for that user's specific transaction. It excludes suggestion lists, other content and POI/address lookups from other services. | The selected venue name and Details address are not made unrestricted by a staff click. This proposed POI-plus-Details workflow does not rely on the narrow street-address exception. [Places policy][policies].                                                                                                                                                                               |

The general and EEA terms pages inspected say last modified **26 August 2026**;
both SST pages say **28 October 2026**; the EEA permitted-uses page says
**4 June 2025**. These public versions are evidence, not confirmation of the
club's accepted, negotiated or reseller terms.

### Owner evidence needed to close the gate

Record the following without putting keys, billing details or private contracts
in this public repository:

1. The intended project, linked billing account's EEA/non-EEA classification,
   agreement/version and any negotiated/reseller terms that affect this use.
   If claiming the unmodified-integration exception, supply its project/workflow
   history and why introducing these Places calls does not end it. The safe
   planning assumption for a new EEA integration is current EEA terms.
2. A contract/legal assessment or written licensing provision that permits the
   exact fields to be retained for workshop history and exported to Calendar,
   including guest copies, update messages and the historical no-rewrite policy.
   Identify the duration and deletion/refresh requirements. A recurring API call
   cannot delete an address already sent to guests.
3. If EEA terms apply, the exact permitted-use category covering each staff and
   attendee use beyond address lookup, and the map/source-link treatment of
   attendee directions and Calendar's native navigation. If no category fits,
   obtain a suitable license or bring the blocker back for a scope decision.
4. An attribution treatment that remains compliant in native Calendar clients,
   plus required application terms/privacy notices. The existing source
   projection and Calendar `location` string do not carry a structured Place or
   attribution contract. [Calendar Events][calendar], [Services list][services].

Google technical support cannot grant terms exceptions; the policy directs
contract interpretation to counsel and custom licensing to Sales. This task
has not contacted either, accepted terms or accessed the Console.
[Places policy][policies]. Once documentary permission is established, update
this record and the affected ticket before implementing Google-derived storage.
Native Calendar UX acceptance remains a separately authorized ALE-445 task.

## Field-by-field destination contract

"Transient" below means only the current permitted lookup/display interaction,
with no reusable cache or durable copy. There is **no approved numeric cache
TTL** for Places text here. All Google display permissions remain conditional
on the applicable terms and attribution; this table does not enable the feature.

| Field / origin                                                                                     | Display and permitted use                                                                                                                                                                                                | Persistence, refresh and deletion                                                                                                                                                                                                                                                         | Calendar export                                                                                                                  |
| -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Existing short label, independently staff-authored                                                 | Existing workshop/email copy; keep it separate from provider text and the Beginners' Workshop 80-character limit unchanged.                                                                                              | Existing domain lifetime; no Places refresh. Never overwrite automatically from `displayName`.                                                                                                                                                                                            | Existing label fallback is unaffected.                                                                                           |
| Manual destination name/address and optional manual Maps link, independently supplied              | Staff and attendee destination display; link validation still applies.                                                                                                                                                   | Source-owned storage; replace/clear explicitly, preserve on omission. Manual replacement removes stale Google identity/derived links.                                                                                                                                                     | Native name/address permitted by this Places assessment; UX remains to be checked. Do not put the link in the event description. |
| Autocomplete `text.text` / structured prediction text                                              | Suggestions only, with Google Maps attribution. Do not treat the prediction as resolved Details fields.                                                                                                                  | Transient; discard on replacement/abandonment/unmount. No database, logs, snapshots, persistent form drafts or fixtures of real responses.                                                                                                                                                | No.                                                                                                                              |
| Details `displayName.text`                                                                         | Selected-result preview and fresh permitted in-app display, with attribution. Attendee display needs its own permitted-use assessment.                                                                                   | No durable storage permission established. Fetch fresh for a permitted interaction; discard afterwards. Neither a 30-day cache nor lifetime retention is approved.                                                                                                                        | Gated: no published exception established.                                                                                       |
| Details `formattedAddress`                                                                         | Same as name. This Details address does not inherit the narrow Autocomplete street-address exception.                                                                                                                    | Same as name. Do not store the address in a constructed URL or short label to evade the rule.                                                                                                                                                                                             | Gated: no published exception established.                                                                                       |
| Place ID (`id`, autocomplete `placeId`)                                                            | Lookup identity; may be used in Maps URLs subject to the applicable linking rules. It is not a human-readable destination.                                                                                               | Indefinite ID storage permitted. Keep an application timestamp and refresh IDs older than 12 months as Google recommends, using Details `id` only. Remove on explicit destination clear/replacement. A failed/obsolete/moved ID requires review, never automatic selection or relocation. | No ID-only substitute: Calendar has no ordinary structured Place-ID location field.                                              |
| Application provenance (`provider: google`, selected/ID-checked time, permission-record reference) | Distinguishes restricted Google facts from independent manual facts.                                                                                                                                                     | Application-generated metadata can follow the owning destination; no query, credential or result body is needed. Keep provenance with the retained ID and any separately licensed retained content.                                                                                       | Internal only.                                                                                                                   |
| Details `attributions[].{provider,providerUri}` and Google Maps branding                           | All returned provider credits stay with the result; branding is required separately.                                                                                                                                     | Transient alongside transient text. If future licensing permits retained text, retain its associated required attributions under that license too; an empty provider list never removes Google Maps branding.                                                                             | No verified native-location treatment; must be resolved with export permission.                                                  |
| Details `googleMapsUri` / `googleMapsLinks`                                                        | Provider source links can be used in permitted in-app display; a general place URL is not necessarily directions.                                                                                                        | Not requested in the chosen mask; no durable URI cache is approved.                                                                                                                                                                                                                       | Not exported.                                                                                                                    |
| Locally constructed directions URL                                                                 | Manual destination text is supported; a retained ID plus independently supplied destination text can technically form a link. Google-derived name/address in the URL remains gated, including EEA map-link restrictions. | Construct on read; do not persist a second copy of restricted provider text. Manually supplied URLs are stored as manual input.                                                                                                                                                           | No description workaround; native Calendar location still requires permitted name/address facts.                                 |
| Raw responses, coordinates, reviews, photos, ratings, contact details                              | Not needed or requested.                                                                                                                                                                                                 | No storage, public projection, job arguments or durable fixtures. Coordinates' 30-day exception does not authorize other fields.                                                                                                                                                          | No.                                                                                                                              |

The Place-ID refresh recommendation and indefinite-ID permission come from the
[Place IDs guide][place-ids] and [Places policy][policies]. An ID refresh that
indicates a moved place must not move a published workshop. Refreshing display
facts also cannot silently rewrite past Calendar events. These consequences are
why storing just an ID and resolving at sync time does not satisfy the agreed
durable export requirement.

## Attribution and user notices

For any later permitted Google path, implement and test these obligations from
the [current Places policy][policies], general terms §3.2.2 and EEA terms
§§3.2.2/3.2.4 plus SST A.2:

- Suggestions need visible **Google Maps** attribution in the same visual
  container as the Google list. Use Google's official logo where possible;
  "Google Maps" text is allowed where space is limited. Do not use an old
  "powered by Google" example as the specification for a new implementation.
- The resolved selection needs attribution beside its Google name/address,
  even after the suggestions close. Render returned data-provider names/links
  too. Escape and validate these fields; do not inject provider HTML.
- Any permitted attendee display needs the same associated branding/provider
  credits on every member, external-attendee and safe Intake surface, not just
  a footer on the staff form. A directions link alone is not attribution.
- Preserve result/credit association on retained licensed content, including
  read models and any export where the permission requires it. A Place ID or
  `provider: google` marker alone is not visible attribution. Calendar is a
  separate unresolved export surface; being another Google product does not
  prove compliance.
- Visually distinguish provider facts from the staff-owned label/manual data;
  do not suggest Google supplied manual values. Follow Google's current logo
  sizing, clear-space, legibility and accessible-name requirements. Text
  attribution must remain "Google Maps", unmodified, untranslated and unwrapped,
  with the documented accessible typography. Do not hide credits on mobile.
- Application terms must notify users of Google Maps features/content and link
  the Google Maps End User Additional Terms and Google Privacy Policy as the
  applicable agreement requires. Review the app's privacy/consent notices
  before activation; these requirements are not satisfied by this repository
  document. [General terms][terms], [EEA terms][eea-terms].

## Lookup integration

The technical choice is **Places API (New) REST: Autocomplete (New), then Place
Details (New) on deliberate selection**, called by Phoenix through one
domain-neutral Req/Req.Test boundary. It has no Workshop IDs, source writes or
Calendar authority. A supported HTTP integration does not by itself authorize
retention or Calendar export; the terms decision above governs those uses.
[Autocomplete guide][autocomplete], [Details guide][details].

Choose a custom suggestions UI rather than a Google JavaScript widget so the
existing shared form and UI primitives can own keyboard interaction and manual
fallback. No Maps JavaScript loader, map, browser Google key, staff geolocation,
Geocoding API, Routes API or venue directory is required by this choice.

### Application-facing lookup contract

These are proposed boundary shapes, not implemented endpoints or a database
schema. Later HTTP exposure is OpenAPI-first and capability-gated for the staff
who can use the relevant forms; the lookup is not a public arbitrary Google
proxy. Both source domains keep their own save commands.

| Operation | Input                                                    | Closed output                                                                                                       |
| --------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Suggest   | Venue query and a fresh opaque search-session token      | `ready` with ordered `{placeId, text}` suggestions (including an empty list), or `unavailable` with a closed reason |
| Resolve   | The explicitly selected `placeId` and that session token | `ready` with `{provider: "google", placeId, name, address, attributions}`, or `unavailable` with a closed reason    |

`name` and `address` in a resolved result are transient Google-derived preview
text, not proof that either field may be saved. `attributions` is a closed list
of `{provider, uri}` obtained from Google's attribution fields; Google Maps
branding is an additional display obligation. Do not return raw Google JSON,
credentials, error bodies, arbitrary URLs, photos, reviews or coordinates.

Suggested failure vocabulary is `not_configured | disabled | invalid_input |
not_found | quota | provider_unavailable`. Authentication/configuration errors
are monitored without exposing their upstream response. No result is an ordinary
empty success. Bound input size, rate and request duration, and check the
caller's capability before spending provider quota. A session token is a billing
correlator, never authorization or a source-workflow credential.

### Provider request and response mapping

1. Suggest uses `POST https://places.googleapis.com/v1/places:autocomplete`,
   `Content-Type: application/json` and server-only `X-Goog-Api-Key`.
   The JSON body contains `input`, `sessionToken`, `languageCode: "en"`,
   `regionCode: "ie"` and this fixed application bias:

   ```json
   {
     "locationBias": {
       "circle": {
         "center": { "latitude": 53.3498, "longitude": -6.2603 },
         "radius": 30000
       }
     }
   }
   ```

   The Dublin centre/radius are application choices, not a venue coordinate
   requirement. Omit `locationRestriction`, `includedRegionCodes`, type filters
   and `origin`. Leave query predictions and pure service-area businesses off.
   `locationBias` permits results outside the circle; `regionCode` influences
   ranking/formatting without a country exclusion. Do not rely on the server's
   IP-derived default bias. [Request reference][autocomplete-reference].

2. Set `X-Goog-FieldMask` to
   `suggestions.placePrediction.placeId,suggestions.placePrediction.text.text`.
   Map only `suggestions[].placePrediction.placeId` and `.text.text` into the
   closed suggestion. Render that text as text, not HTML. Do not parse it into a
   destination name/address: prediction text can differ from Details. Ignore
   unsupported prediction variants; an empty or omitted suggestions array is
   empty success. [Autocomplete fields][autocomplete-reference].

3. Resolve uses `GET https://places.googleapis.com/v1/places/{placeId}` with the
   Place ID encoded as one path segment, fixed host/path construction,
   `sessionToken` and `languageCode=en` query parameters, and server-only
   `X-Goog-Api-Key`. Do not set a Details `regionCode`, so an Irish country name
   is not deliberately omitted from the full address. Use exactly
   `X-Goog-FieldMask: id,displayName,formattedAddress,attributions`.
   Map `id`, `displayName.text`, `formattedAddress` and
   `attributions[].{provider,providerUri}`. In New, `name` is the resource name
   `places/…`, not the human-readable `displayName`. Missing required identity
   or useful destination text cannot be repaired by guessing from a suggestion;
   offer manual entry. [Details guide][details], [Place reference][place].

4. Generate a random UUID v4 per interaction. Use the same token for all its
   suggestions and its one terminating Details request, with credentials from
   the same Google Cloud project. Discard on resolution or abandonment; start a
   new token for replacement. Never reuse an Intake, login, acceptance or
   Calendar token. Google recommends sessions; an abandoned session remains
   billable per autocomplete request. An ID-only refresh is separate from a
   search session. [Session tokens][tokens], [session billing][session-pricing].

5. Debounce/cancel superseded searches and reject late results by the current
   request/selection identity. Keep result/selection text in component memory
   only and clear on replacement, abandonment or unmount. Serve lookup
   responses with `Cache-Control: no-store`; exclude them from CDN, service
   worker and browser persistent storage. Provider errors, slow requests or
   absent configuration must leave the label/manual fields and save operation
   usable. No speculative first-result selection or automatic save is allowed.

### Data leaving the application

Places receives the venue query or selected Place ID, random session token,
fixed language/region/bias, field mask and authentication. Google also observes
the server's network metadata. Construct fresh outbound requests; do not forward
browser cookies, authorization, client-IP headers, Referer or a page URL.
Search controls must warn staff to enter venue information only. Do not attach
Workshop titles, IDs, dates, attendees, private notes, medical/payment facts or
Intake credentials. Prevent request/response bodies and query strings from
entering logs, analytics, Sentry breadcrumbs or durable test fixtures.

Attendee navigation is an explicit link click, with only destination facts in
the URL, no tracking/session tokens or origin location supplied by this app.
Keep the Intake `Referrer-Policy: no-referrer` response and use referrer-safe
external links on every attendee surface. Google Maps itself may ask the user
for an origin after navigation; the dashboard must not request location access.

## Directions URL decision

Use the documented universal URL format when a permitted destination is
available:

```text
https://www.google.com/maps/dir/?api=1&destination=<encoded destination>
```

For a permitted Google identity and independently supplied destination text,
`destination_place_id=<encoded Place ID>` can also be supplied; `destination`
is still required. Google-derived destination text remains gated. Build with a
URL encoder, omit `origin`, and respect the 2,048-character URL limit. Maps URLs need no API
key. This is a link, not a fetched/cached route. It does not add structured Place
identity to Calendar's free-form location field. [Maps URLs][maps-urls].

Do not request or persist `googleMapsUri`: its documented meaning is a URL for
more information about the place, not specifically directions, and it has no
separately established long-term storage permission here. A locally constructed
URL does not remove restrictions on Google-derived text embedded in it.
[Place reference][place]. Independently supplied manual Maps links remain
optional and go through the source's HTTPS/host/path/credential validation;
validation must not fetch arbitrary URLs or silently resolve shortened links.

## Configuration and operational readiness

These are requirements for a separately authorized setup, not tasks run by
this validation:

- A chosen Google Cloud project with billing enabled and **Places API (New)**
  (`places.googleapis.com`) enabled. Record its linked billing account and
  applicable agreement before enabling the provider. Existing Calendar API
  enablement and organizer OAuth establish none of these facts. [Setup][setup].
- A dedicated server-side Places key, stored as a secret, restricted to Places
  API (New) and the actual public egress IP addresses Google sees, including
  IPv6 where used. HTTP-referrer restrictions are for browser keys, not this
  REST server key. Confirm stable egress before activation; inability to apply
  the restriction is a deployment blocker, not permission to ship an
  unrestricted key. Use separate environment credentials and bounded quotas.
  [Key security][security].
- No key is intentionally browser-exposed in the chosen integration. If the
  integration later changes to Maps JavaScript, reopen this choice: its distinct
  browser key is public by design and needs website/referrer and the required
  API restrictions. Never reuse the server key or broaden Calendar OAuth to
  make autocomplete work. [Key security][security].
- `displayName` triggers the Details Pro field tier, while `formattedAddress`
  is Essentials and `id`/`attributions` are IDs Only fields. Do not estimate cost
  by field tier alone: the current session pricing page says a non-Essentials
  terminating Details request is billed as **Enterprise + Atmosphere**, with
  autocomplete requests in that session billed as Session Usage. Abandoned
  sessions revert to per-request charges. The owner must review current rates,
  quotas and alerts; this document makes no zero-cost promise. [Details
  fields][details], [session pricing][session-pricing].
- Provider availability must require explicit configuration and the completed
  terms gate. Unconfigured, disabled, invalid-key and quota-exhausted states
  degrade to manual scheduling. Calendar sending keeps its separate target-bound
  activation gate. No saved manual destination may depend on a Places read.

## Compliance checks for ALE-442

Before code is authorized, the owner evidence above must resolve the full
Google-selected save/read/Calendar path. Keep ALE-439 open as the blocker until
then; this document records the validation outcome without clearing that gate.
Manual-only tickets do not wait on it. Once resolved, extend the approved test
seams in ALE-438 with:

- Synthetic Req.Test assertions for the exact POST/GET, masks, Dublin bias,
  session lifecycle and closed mapping, including missing fields/attributions,
  out-of-region results, empty success, invalid/obsolete IDs and failures.
  Tests fail on any unhandled real provider request.
- Checks that only permitted fields reach each domain's saved/read contracts,
  that omitted/cleared/replaced destinations behave correctly, and that
  manual edits cannot keep an unrelated Google identity. Real Google response
  fixtures, logs, analytics, Sentry and browser storage must remain empty.
- Browser/E2E assertions for attribution while suggesting, after selection and
  on every attendee surface; verify mobile and accessible presentation with
  non-empty synthetic third-party credits. Independent manual values receive
  no false provider attribution.
- Clock-controlled ID refresh and every additional field retention/deletion
  rule established by the final agreement, including its treatment of backups,
  history, Calendar copies and expired data during provider outages. Default
  denial must prevent accidental caching/export of unapproved fields.
- Full selected-destination round trips through all four forms, attendee-safe
  reads and both source Calendar projections. Assert no private credentials or
  attendee facts reach Places or navigation URLs/referrers, and manual saves
  remain available when Places is unavailable or gated.
- Existing substituted Calendar sync assertions for native location and normal
  updates/no-op silence, without changing descriptions, identity, RSVP or
  enrichment-versus-reschedule semantics. Isolated live UX checks are separate;
  a successful write does not establish either licensing or navigation quality.

## Sources

All sources are first-party Google documentation, accessed 6 November 2026.
They establish public rules and API shapes, not the club's account agreement.

[terms]: https://cloud.google.com/maps-platform/terms
[sst]: https://cloud.google.com/maps-platform/terms/maps-service-terms
[eea-terms]: https://cloud.google.com/terms/maps-platform/eea
[eea-sst]: https://cloud.google.com/terms/maps-platform/eea/maps-service-terms
[eea-uses]: https://cloud.google.com/terms/maps-platform/eea-places-api-permitted-uses
[eea-faq]: https://developers.google.com/maps/comms/eea/faq
[eea-guide]: https://developers.google.com/maps/comms/eea/places
[policies]: https://developers.google.com/maps/documentation/places/web-service/policies
[place-ids]: https://developers.google.com/maps/documentation/places/web-service/place-id
[calendar]: https://developers.google.com/workspace/calendar/api/v3/reference/events#location
[services]: https://cloud.google.com/maps-platform/terms/maps-services
[autocomplete]: https://developers.google.com/maps/documentation/places/web-service/place-autocomplete
[autocomplete-reference]: https://developers.google.com/maps/documentation/places/web-service/reference/rest/v1/places/autocomplete
[details]: https://developers.google.com/maps/documentation/places/web-service/place-details
[place]: https://developers.google.com/maps/documentation/places/web-service/reference/rest/v1/places
[tokens]: https://developers.google.com/maps/documentation/places/web-service/place-session-tokens
[session-pricing]: https://developers.google.com/maps/documentation/places/web-service/session-pricing
[maps-urls]: https://developers.google.com/maps/documentation/urls/guide
[setup]: https://developers.google.com/maps/documentation/places/web-service/get-api-key
[security]: https://developers.google.com/maps/api-security-best-practices
