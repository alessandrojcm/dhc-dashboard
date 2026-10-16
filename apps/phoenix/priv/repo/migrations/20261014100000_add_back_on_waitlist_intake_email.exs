defmodule Dhc.Repo.Migrations.AddBackOnWaitlistIntakeEmail do
  @moduledoc """
  ALE-412: the "Back on the Waitlist" Intake Email (`back_on_waitlist`, a
  notice with `{{firstName}}`), sent when a person's reply puts them back on
  the Waitlist. Widens the template table's type check and seeds the row's
  default copy; later edits belong to the coordinator, not to code.

  Deploy shape: additive. The old code never reads the new row; run before
  the code that queues it.
  """

  use Ecto.Migration

  @previous_types ~w(contact_pay contact_confirm place_confirmed_paid place_confirmed_carried
             pre_workshop rescheduled follow_up declined deferred cancelled_with_refund
             withdrawn_refunded withdrawn_forfeited carried_fee_refunded payment_refunded
             cancelled_paid cancelled_unpaid)

  @types @previous_types ++ ~w(back_on_waitlist)

  @table :beginners_workshop_email_templates
  @check :beginners_workshop_email_templates_email_type_check

  def up do
    replace_check(@types)
    flush()

    now = DateTime.utc_now()

    repo().insert_all(
      "beginners_workshop_email_templates",
      [
        %{
          email_type: "back_on_waitlist",
          subject: "You're back on the Beginners' Workshop waitlist",
          body: body(),
          created_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:email_type]
    )
  end

  def down do
    execute(
      "DELETE FROM beginners_workshop_email_templates WHERE email_type = 'back_on_waitlist'"
    )

    replace_check(@previous_types)
  end

  defp replace_check(types) do
    drop_if_exists constraint(@table, @check)

    create constraint(@table, @check,
             check: "email_type IN (#{Enum.map_join(types, ", ", &"'#{&1}'")})"
           )
  end

  defp body do
    %{
      "type" => "doc",
      "content" => [
        p([
          %{"type" => "text", "text" => "Hi "},
          %{"type" => "placeholder", "attrs" => %{"name" => "firstName"}},
          %{"type" => "text", "text" => ","}
        ]),
        p([
          %{
            "type" => "text",
            "text" =>
              "As you asked, we've put you back on the waitlist, and you haven't lost your turn in the queue. We'll be in touch when we can offer you a workshop place."
          }
        ]),
        p([
          %{"type" => "text", "text" => "Regards,"},
          %{"type" => "hardBreak"},
          %{"type" => "text", "text" => "Dublin HEMA Club"}
        ])
      ]
    }
  end

  defp p(inline), do: %{"type" => "paragraph", "content" => inline}
end
