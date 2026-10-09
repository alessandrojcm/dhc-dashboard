defmodule Dhc.Repo.Migrations.CreateBeginnersWorkshopEmailTemplates do
  @moduledoc """
  Intake Email templates (ALE-377): one club-wide row per email type, holding
  the subject (plain text with `{{placeholder}}` tokens) and the Tiptap body
  (`placeholder` nodes for the same vocabulary). Phoenix fills a template when
  an email is queued, so editing a row affects only later emails.

  The rows are seeded here from the club's current manual email copy, so every
  environment can queue every type. The copy is frozen in this migration on
  purpose: later edits belong to the coordinator, not to code.

  Deploy shape: additive (a new table), safe before or after the code.
  """

  use Ecto.Migration

  @types ~w(contact_pay contact_confirm place_confirmed_paid place_confirmed_carried
            pre_workshop rescheduled follow_up declined deferred cancelled_with_refund
            withdrawn_refunded withdrawn_forfeited carried_fee_refunded payment_refunded
            cancelled_paid cancelled_unpaid)

  def up do
    create table(:beginners_workshop_email_templates, primary_key: false) do
      add :email_type, :text, primary_key: true
      add :subject, :text, null: false
      add :body, :map, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      constraint(
        :beginners_workshop_email_templates,
        :beginners_workshop_email_templates_email_type_check,
        check: "email_type IN (#{Enum.map_join(@types, ", ", &"'#{&1}'")})"
      )
    )

    create(
      constraint(
        :beginners_workshop_email_templates,
        :beginners_workshop_email_templates_subject_check,
        check: "char_length(btrim(subject)) > 0 AND char_length(subject) <= 200"
      )
    )

    flush()

    now = DateTime.utc_now()

    rows =
      for {type, subject, body} <- seed() do
        %{email_type: type, subject: subject, body: body, created_at: now, updated_at: now}
      end

    repo().insert_all("beginners_workshop_email_templates", rows)
  end

  def down do
    drop table(:beginners_workshop_email_templates)
  end

  # ── Seed copy ────────────────────────────────────────────────────────

  defp seed do
    [
      {"contact_pay", "A place at our Beginners' Workshop on {{date}}",
       doc([
         greeting(),
         p(
           text(
             "Good news: you're near the top of our waitlist, and we'd love to see you at our next Beginners' Workshop on "
           ) ++
             bold("{{date}} at {{startTime}}") ++
             text(", at {{venue}}. The fee is {{fee}}.")
         ),
         p(
           text("Our waitlist is long, so please pay by ") ++
             bold("{{windowEnd}}") ++
             text(
               ". Payments stay open until {{paymentCutoff}}, but places go to whoever pays first, so after {{windowEnd}} your place may be offered to someone else."
             )
         ),
         p(
           text(
             "If you can't make this date, just reply to this email and we'll keep your place in the queue."
           )
         ),
         sign_off("See you on the floor,")
       ])},
      {"contact_confirm", "Confirm your place at our Beginners' Workshop on {{date}}",
       doc([
         greeting(),
         p(
           text("Our next Beginners' Workshop is on ") ++
             bold("{{date}} at {{startTime}}") ++
             text(
               ", at {{venue}}. You already have a place paid for from an earlier workshop, so there's nothing to pay."
             )
         ),
         p(
           text("Please confirm you can make it by ") ++
             bold("{{windowEnd}}") ++
             text(
               ". Places go to whoever confirms or pays first, and confirmations close at {{paymentCutoff}}."
             )
         ),
         p(
           text(
             "If you can't make this date, just reply to this email: we'll keep your fee and your place in the queue."
           )
         ),
         sign_off("See you on the floor,")
       ])},
      {"place_confirmed_paid", "Your place on {{date}} is confirmed",
       doc([
         greeting(),
         p(
           text("Thanks for paying {{fee}}. Your place at the Beginners' Workshop on ") ++
             bold("{{date}} at {{startTime}}") ++ text(", at {{venue}}, is confirmed.")
         ),
         p(text("We'll send you everything you need to know a few days before the workshop.")),
         sign_off("See you on the floor,")
       ])},
      {"place_confirmed_carried", "Your place on {{date}} is confirmed",
       doc([
         greeting(),
         p(
           text("Your place at the Beginners' Workshop on ") ++
             bold("{{date}} at {{startTime}}") ++
             text(", at {{venue}}, is confirmed, using the fee you already paid.")
         ),
         p(text("We'll send you everything you need to know a few days before the workshop.")),
         sign_off("See you on the floor,")
       ])},
      {"pre_workshop", "See you on {{date}}: your Beginners' Workshop",
       doc([
         greeting(),
         p(
           text("See you on ") ++
             bold("{{date}} at {{startTime}}") ++ text(" at {{venue}}.")
         ),
         p(
           text(
             "Wear comfortable clothes you can move in and indoor runners, and bring water. We provide all the equipment."
           )
         ),
         p(text("Please arrive a few minutes early so we can start on time.")),
         sign_off("See you on the floor,")
       ])},
      {"rescheduled", "Your Beginners' Workshop has moved to {{date}}",
       doc([
         greeting(),
         p(
           text("We've had to move the workshop. It's now on ") ++
             bold("{{date}} at {{startTime}}") ++ text(", at {{venue}}.")
         ),
         p(
           text(
             "Your place carries over, so there's nothing you need to do. If you haven't paid yet, payments stay open until {{paymentCutoff}}."
           )
         ),
         p(text("If the new date doesn't work for you, just reply to this email.")),
         sign_off("Sorry for the change,")
       ])},
      {"follow_up", "Thanks for coming on {{date}}",
       doc([
         greeting(),
         p(text("Thanks for coming to our Beginners' Workshop on {{date}}!")),
         p(
           text(
             "Your first regular class is free: come along any Tuesday or Thursday. We'll also send you an invitation to join the club."
           )
         ),
         sign_off("See you on the floor,")
       ])},
      {"declined", "We've kept your place in the queue",
       doc([
         greeting(),
         p(
           text(
             "No problem, we've noted that you can't make the workshop on {{date}}. We've kept your place in the queue and we'll be in touch about a later workshop."
           )
         ),
         sign_off("Regards,")
       ])},
      {"deferred", "We've kept your fee for a later workshop",
       doc([
         greeting(),
         p(
           text(
             "We've moved you off the workshop on {{date}} and kept your fee for a later one. You keep your place in the queue, and you'll hear from us when the next workshop is scheduled."
           )
         ),
         sign_off("Regards,")
       ])},
      {"cancelled_with_refund", "Your refund for the Beginners' Workshop on {{date}}",
       doc([
         greeting(),
         p(
           text(
             "We've cancelled your place on {{date}} and refunded {{refundAmount}}. It can take a few days to reach your account. You're still in the queue for a later workshop."
           )
         ),
         sign_off("Regards,")
       ])},
      {"withdrawn_refunded", "You've left the Beginners' Workshop waitlist",
       doc([
         greeting(),
         p(
           text(
             "As you asked, we've removed you from the waitlist and refunded {{refundAmount}}. It can take a few days to reach your account."
           )
         ),
         p(text("You're welcome to register again whenever you like.")),
         sign_off("Regards,")
       ])},
      {"withdrawn_forfeited", "You've left the Beginners' Workshop waitlist",
       doc([
         greeting(),
         p(text("As you asked, we've removed you from the waitlist.")),
         p(text("You're welcome to register again whenever you like.")),
         sign_off("Regards,")
       ])},
      {"carried_fee_refunded", "We've refunded your Beginners' Workshop fee",
       doc([
         greeting(),
         p(
           text(
             "We've refunded the {{refundAmount}} you paid. It can take a few days to reach your account. You're still in the queue, and next time we'll ask you to pay as usual."
           )
         ),
         sign_off("Regards,")
       ])},
      {"payment_refunded", "We've refunded your payment",
       doc([
         greeting(),
         p(
           text(
             "Your payment of {{refundAmount}} for the workshop on {{date}} arrived after your place had closed, so we've refunded it in full. It can take a few days to reach your account."
           )
         ),
         p(text("If you have any questions, just reply to this email.")),
         sign_off("Regards,")
       ])},
      {"cancelled_paid", "The Beginners' Workshop on {{date}} is cancelled",
       doc([
         greeting(),
         p(text("We're sorry, we've had to cancel the Beginners' Workshop on {{date}}.")),
         p(
           text(
             "We've kept your fee for a later workshop, and you keep your place in the queue, so you don't need to do anything. If you'd prefer a refund, just reply to this email."
           )
         ),
         sign_off("Sorry for the trouble,")
       ])},
      {"cancelled_unpaid", "The Beginners' Workshop on {{date}} is cancelled",
       doc([
         greeting(),
         p(text("We're sorry, we've had to cancel the Beginners' Workshop on {{date}}.")),
         p(
           text(
             "You keep your place in the queue, and we'll be in touch when the next workshop is scheduled."
           )
         ),
         sign_off("Sorry for the trouble,")
       ])}
    ]
  end

  defp doc(blocks), do: %{"type" => "doc", "content" => blocks}
  defp p(inline), do: %{"type" => "paragraph", "content" => inline}
  defp greeting, do: p(text("Hi {{firstName}},"))

  defp sign_off(close),
    do: p(text(close) ++ [%{"type" => "hardBreak"}] ++ text("Dublin HEMA Club"))

  defp text(source), do: inline(source, [])
  defp bold(source), do: inline(source, [%{"type" => "bold"}])

  # Splits copy on `{{name}}` into text and placeholder nodes sharing `marks`.
  defp inline(source, marks) do
    ~r/(\{\{[A-Za-z]+\}\})/
    |> Regex.split(source, include_captures: true, trim: true)
    |> Enum.map(fn
      "{{" <> rest ->
        node(
          %{"type" => "placeholder", "attrs" => %{"name" => String.trim_trailing(rest, "}}")}},
          marks
        )

      chunk ->
        node(%{"type" => "text", "text" => chunk}, marks)
    end)
  end

  defp node(node, []), do: node
  defp node(node, marks), do: Map.put(node, "marks", marks)
end
