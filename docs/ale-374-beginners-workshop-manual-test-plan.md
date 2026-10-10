# Beginners' Workshop v1: manual test plan

ALE-374 has unit, browser and Playwright coverage. The Playwright journey does
call the real Stripe test API, but only to create the Checkout Session: it
checks the redirect to a `cs_test_` Checkout URL, stubs Stripe's hosted page,
and completes the payment through the E2E harness (`complete_payment` with a
made-up completed session). No card is entered, no Stripe webhook arrives, and
no Beginners' Workshop refund reaches Stripe. This checklist covers what the
automated suites don't: paying, declining and abandoning a real test-mode
Checkout, webhooks and refunds (including failed ones), time passing (Batches,
cutoff, finalisation, retention), and the edges between tickets. Cases marked
**(review fix)** exercise code changed after the code-and-spec review, so test
them first.

## Setup

1. **Reset the dev database.** The Beginners' Workshop seeds grow with each
   ticket, so wipe the database, migrate, and reseed with the current code:

   ```bash
   docker compose stop db && docker compose rm -f db \
     && docker volume rm dhc-dashboard_dhc_postgres_data \
     && docker compose up -d --wait db
   mise run phx-setup
   for t in seed-committee seed-members seed-waitlist seed-invitations seed-workshops \
            seed-inventory seed-beginners-workshops; do mise run $t; done
   ```

2. **Accounts.** `scripts/users.csv` (gitignored) feeds `mise run seed-committee`.
   Besides `admin@example.com`, add a beginners coordinator, a coach and a
   plain member to act as an assistant, so Staff, the door and
   assignment-scoped access can be tested. Use the same header and columns as
   the existing row:

   ```csv
   beginners@example.com,Coordinator,"beginners_coordinator,member",Clare,Coordinator,01/01/1990,she/her,female,Next of Kin,+353820000001,longsword,
   coach@example.com,Coach,"coach,member",Aoife,Coach,01/01/1988,she/her,female,Next of Kin,+353820000002,longsword,
   assistant@example.com,Assistant,member,Brian,Assist,01/01/1992,he/him,male,Next of Kin,+353820000003,longsword,
   ```

3. **Run the app.** `mise run phx-server` (Phoenix on :4000) and `mise run dev`
   (SvelteKit on :5173). `docker compose up -d mailpit` if it isn't running.
   Every email lands in Mailpit at <http://localhost:8025>: magic-link sign-ins,
   Contact emails (with the Intake link), and every notice.

4. **Stripe webhooks.** Checkout uses real Stripe test mode with the `.env` key.
   Forward webhooks to the local Phoenix and put the printed `whsec_…` in `.env`
   as `STRIPE_WEBHOOK_SIGNING_SECRET` (restart Phoenix after):

   ```bash
   stripe listen --forward-to localhost:4000/api/webhooks/stripe
   ```

5. **Moving time.** The sweep runs every 5 minutes on real time. To run the
   Batch, reaper, cutoff, finalisation, Follow-up and retention passes at a
   chosen instant, use `mise run phx-console`:

   ```elixir
   alias Dhc.BeginnersWorkshops.Clock
   # 10:00 Dublin on 20 October 2026 (Irish summer time is UTC+1 until 25 October)
   Dhc.BeginnersWorkshops.run_due_passes(clock: Clock.fixed(~U[2026-10-20 09:00:00Z]))
   ```

   Commands clicked in the UI always use real time. Use the console only for
   passes, and expect the UI to judge "now" differently from your fixed clock.

6. **Stripe test cards.** `4242 4242 4242 4242` succeeds;
   `4000 0000 0000 0002` is declined; `4000 0000 0000 5126` succeeds, but a
   later refund of it fails asynchronously. To end a Checkout Session at once:
   `stripe checkout sessions expire cs_test_…`.

7. **Door tests.** Check-in opens an hour before the start. Reschedule a
   workshop to today with a start time less than an hour away.

## 1. Waitlist and registration

- [ ] **1. Silent duplicate registration.** Register publicly with an email
  already on the Waitlist, then with one that has a pending Invitation.
  *Expect:* both look like a success; no entry is created.
- [ ] **2. No email oracle (review fix).** Register with a first name of 41 or
  more characters, once with a known email and once with a new one.
  *Expect:* the same 422 both times.
- [ ] **3. Staff add a new person.** Use an email on the Waitlist, a member's
  email, and one with a pending Invitation. *Expect:* a visible refusal naming
  each reason.
- [ ] **4. Remove and restore.** Remove someone, then restore them; switch the
  Waitlist standing toggle. *Expect:* restore keeps the original queue date;
  the removed view lists them.
- [ ] **5. Delete a person.** Try it with a held Carried Fee, with an open
  Intake, and for someone invited or joined. *Expect:* the refund-or-forfeit
  choice first / refused with an open Intake / refused as not deletable.

## 2. Scheduling, Staff and reschedule

- [ ] **6. Unstaffed (review fix).** Schedule with no Staff, then assign only an
  assistant. *Expect:* "Unstaffed: no Staff assigned", which disappears once
  anyone is assigned.
- [ ] **7. All-or-nothing scheduling.** Schedule several at once where one has
  a contact-from after its cutoff. *Expect:* nothing scheduled; the error sits
  on that row's field.
- [ ] **8. Notifications reach the actor (review fix).** Assign or unassign
  yourself as Staff, reschedule, and cancel. *Expect:* you receive the
  Notification too.
- [ ] **9. Clock change.** Reschedule across 25 October. *Expect:* the cutoff
  keeps its Dublin time of day.
- [ ] **10. Contact-from never after the cutoff (review fix).** Reschedule so
  close that today is past the new cutoff. *Expect:* the stored contact-from is
  on or before the cutoff.
- [ ] **11. Reschedule after Batch 1.** Supply a new contact-from. *Expect:*
  refused as locked; open Batch windows shrink to the new cutoff.
- [ ] **12. Cutoff edits clamp windows (review fix).** In Settings, move the
  cutoff earlier while a Batch window is open. *Expect:* that person's Intake
  page shows the earlier deadline.
- [ ] **13. Assignment scope.** Sign in as the coach. Open My Beginners'
  Workshops, then the door URL of a workshop you aren't on. *Expect:* only
  your workshops; the other door is a 404.

## 3. Batches (console passes)

- [ ] **14. Batch 1.** Run the passes at 10:00 Dublin on the contact-from day.
  *Expect:* the oldest waiting people, up to capacity, matching the console's
  Next Batch preview; Contact emails in Mailpit; one "Batch sent"
  Notification.
- [ ] **15. Idempotent sweep.** Run the passes again at the same instant.
  *Expect:* no second Batch, no repeated emails.
- [ ] **16. Nobody waiting.** A due Batch with nobody waiting; run twice.
  *Expect:* one "nobody waiting" alert.
- [ ] **17. Pause.** Pause Batches, run the passes, resume. *Expect:* nothing is
  sent while paused.

## 4. Intake page and payment

Open the Intake page from the Contact email in Mailpit.

- [ ] **18. Happy path.** Pay with `4242…`. *Expect:* "Your place is confirmed";
  the seat count rises.
- [ ] **19. Abandoned Checkout.** Press Pay, then close the Checkout tab.
  *Expect:* the seat counts as taken (a second person sees it full at
  capacity); expiring the session frees it.
- [ ] **20. Last seat.** Two people press Pay for the last seat. *Expect:* one
  gets Checkout, the other "full".
- [ ] **21. Declined card.** Pay with `…0002`. *Expect:* still contacted; paying
  again works.
- [ ] **22. Link rotation mid-Checkout (review fix).** Start Checkout, then
  Rotate link in the console and edit the person's email; finish paying in
  the old tab. *Expect:* the payment is recorded, not lost; the old link no
  longer opens the page and the new one does.
- [ ] **23. Reaper mid-Checkout (review fix).** As 22, but run the passes before
  finishing. *Expect:* the hold is not freed while the session can still be
  paid.
- [ ] **24. Decline during Checkout.** Decline the Intake while the person is in
  Checkout, then they pay. *Expect:* an automatic full refund and the
  "Declined" email.
- [ ] **25. No webhook.** Pay with `stripe listen` stopped, then start it again.
  *Expect:* the return page still confirms; the late webhook doesn't count
  the payment twice.
- [ ] **26. Link privacy.** In DevTools, check the Intake page's headers and the
  Phoenix log. *Expect:* `Referrer-Policy: no-referrer`; the token never
  appears in the log.

## 5. Payment Cutoff

- [ ] **27. Lapse.** Run the passes after the cutoff with a seat free and an
  unpaid contacted person. *Expect:* lapsed and removed from the Waitlist.
- [ ] **28. Return.** As 27, but the workshop is full. *Expect:* returned to the
  queue with standing unchanged.
- [ ] **29. Hold open at the cutoff.** A contacted person is mid-Checkout when
  the cutoff passes. *Expect:* left alone until the hold ends; paid if they
  pay.
- [ ] **30. Pre-workshop info.** Paid people at the cutoff; run the passes
  twice. *Expect:* "Pre-workshop info" sent once.

## 6. Console commands and Carried Fees

- [ ] **31. Repeats.** Decline, resend or rotate twice. *Expect:* "already
  done", no extra email; the history shows each with its note.
- [ ] **32. Defer.** Defer a Stripe-paid Intake. *Expect:* a held Carried Fee,
  back to waiting with the original priority, the "Deferred" email.
- [ ] **33. Confirm with a fee.** Fast-track that holder into another workshop.
  *Expect:* the "Contact – confirm" email; the Intake page offers Confirm,
  not Pay; confirming pays it with the fee.
- [ ] **34. Fast-track after the cutoff.** A normal person, then a Carried Fee
  holder. *Expect:* refused / allowed.
- [ ] **35. Withdraw a contacted fee holder (review fix).** From the console.
  *Expect:* the dialog asks refund-or-forfeit and shows the fee's original
  amount (which can differ from this workshop's fee); both choices work.
- [ ] **36. Repeat withdraw and fee refund (review fix).** Withdraw the same
  person again; refund a fee twice. *Expect:* "already done", nothing repeated.
- [ ] **37. Cancel with refund.** On a Stripe-paid Intake, then on a
  Carried-Fee-paid one. *Expect:* a full refund and back to waiting / the fee
  itself is refunded.
- [ ] **38. Retention and fee refunds (review fix).** A person removed more than
  3 months ago holds a fee. *Expect:* Refund Carried Fee is not offered.
- [ ] **39. Imported fee.** Refund an imported fee before linking it, then link a
  `pi_…`. *Expect:* refused, telling staff to link the payment first; after
  linking, the amount comes from Stripe.
- [ ] **40. Failed fee refund.** Pay with `…5126`, defer, then refund the fee.
  *Expect:* the fee is held again; Needs attention offers Retry, Record manual
  refund and Forfeit; the coordinators are alerted.
- [ ] **41. Failed fee refund after a new Stripe payment (review fix).** As 40,
  but the person pays a new Intake by Stripe before the refund fails.
  *Expect:* the fee stays refunded with no Forfeit, and the alert says the
  money is still owed back; Retry works, and so does Defer.

## 7. Door, finalisation and after

- [ ] **42. Before check-in opens.** Open the door more than an hour before the
  start. *Expect:* an "opens at …" notice.
- [ ] **43. Check-in history (review fix).** Check someone in, undo, check in
  again, then unassign that Staff member. *Expect:* the Intake history keeps
  every check-in and undo with who and when, after the unassignment too.
- [ ] **44. Door privacy.** *Expect:* no email, payment or Waitlist fields; a
  Guardian only for a minor.
- [ ] **45. Finish during Checkout.** Press Finish while a contacted person is
  in Checkout. *Expect:* refused as "payment in progress".
- [ ] **46. Automatic finalisation.** Run the passes after the Dublin day ends,
  then at 10:00 the next morning. *Expect:* checked-in people attended, the
  rest no-show; one Follow-up each.
- [ ] **47. Corrections.** Correct attended ↔ no-show and no-show → deferred,
  then try again after inviting. *Expect:* allowed / refused once invited.
- [ ] **48. Invitation handoff.** Invite, delete the Invitation, invite again,
  accept. *Expect:* invited → attended → invited → joined.
- [ ] **49. Expired direct Invitation (review fix).** Send a direct Invitation,
  let it expire, register that email on the Waitlist, then Resend.
  *Expect:* the resend is refused and logged; acceptance can't fail later.

## 8. Cancel, report and retention

- [ ] **50. Cancel a workshop.** With paid, Carried-Fee-paid, contacted and
  checked-in people. *Expect:* paid people hold Carried Fees, contacted people
  go back to waiting, the right emails go out, and later passes ignore the
  workshop.
- [ ] **51. Report (review fix).** Compare the Dashboard tab with the Waitlist
  analytics. *Expect:* the same Waiting number; outstanding Carried Fees
  include applied ones; outcomes list only past workshops; cancelled
  workshops carry no rates.
- [ ] **52. Retention purge.** Run the passes with the clock exactly 3 months
  after someone's removal, then 3 months and a day. *Expect:* not purged /
  purged, with their Intakes anonymised and still counted by the report.
