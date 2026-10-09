defmodule Dhc.BeginnersWorkshops.IntakeEmailsTest do
  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Swoosh.TestAssertions

  alias Dhc.BeginnersWorkshops.IntakeEmails
  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType
  alias Dhc.BeginnersWorkshops.IntakeEmails.Renderer
  alias Dhc.BeginnersWorkshops.IntakeEmails.Values
  alias Dhc.Email.Worker
  alias Dhc.Waitlist.WaitlistEntry

  @person %WaitlistEntry{email: "aoife@example.com"}
  @intake_link "https://dashboard.example.com/beginners/intake/secret-intake-token"

  @values %{
    "firstName" => "Aoife",
    "date" => "Saturday 14 November 2026",
    "startTime" => "10:00",
    "venue" => "St. Michan's Hall",
    "fee" => "€50.00",
    "windowEnd" => "Sunday 8 November 2026, 23:59",
    "paymentCutoff" => "Wednesday 11 November 2026, 23:59",
    "refundAmount" => "€50.00"
  }

  defp doc(blocks), do: %{"type" => "doc", "content" => blocks}
  defp p(content), do: %{"type" => "paragraph", "content" => content}
  defp t(text), do: %{"type" => "text", "text" => text}
  defp ph(name), do: %{"type" => "placeholder", "attrs" => %{"name" => name}}

  defp only_job do
    assert [job] = all_enqueued(worker: Worker)
    job
  end

  describe "seeded templates" do
    test "there is exactly one per Intake Email type" do
      assert Enum.map(IntakeEmails.list_templates(), & &1.email_type) == EmailType.ids()
    end

    test "every seeded template passes the save check" do
      for template <- IntakeEmails.list_templates() do
        assert :ok = Renderer.validate(template.email_type, template.subject, template.body),
               "#{template.email_type} fails its own save check"
      end
    end

    test "no seeded template names Staff" do
      for template <- IntakeEmails.list_templates() do
        refute template.subject <> Jason.encode!(template.body) =~ ~r/coach|assistant/i
      end
    end
  end

  describe "update_template/2" do
    test "saves a template that only uses its type's placeholders" do
      body = doc([p([t("Thanks, "), ph("firstName")])])

      assert {:ok, saved} =
               IntakeEmails.update_template("follow_up", %{
                 subject: "Thanks for {{date}}",
                 body: body
               })

      assert %{subject: "Thanks for {{date}}", body: ^body} = saved
    end

    test "refuses a placeholder the type can't fill, in the subject or the body" do
      assert {:error, changeset} =
               IntakeEmails.update_template("withdrawn_forfeited", %{
                 subject: "See you on {{date}}",
                 body: doc([p([t("Refunded "), ph("refundAmount")])])
               })

      assert %{
               subject: ["uses {{date}}, which this email can't fill"],
               body: ["uses {{refundAmount}}, which this email can't fill"]
             } = errors_on(changeset)

      assert IntakeEmails.get_template!("withdrawn_forfeited").subject =~ "waitlist"
    end

    test "refuses a body over the limit at worst case" do
      assert {:error, changeset} =
               IntakeEmails.update_template("contact_pay", %{
                 body: doc([p(List.duplicate(ph("venue"), 25))])
               })

      assert %{body: [message]} = errors_on(changeset)
      assert message =~ "the limit is 2000"
    end
  end

  describe "queue/4" do
    test "queues an action email filled from the template, with the button link sealed" do
      {:ok, _} =
        IntakeEmails.update_template("contact_pay", %{
          subject: "A place on {{date}}",
          body: doc([p([t("Hi "), ph("firstName"), t(", the fee is "), ph("fee")])])
        })

      assert {:ok, _job} =
               IntakeEmails.queue("contact_pay", @person, @values, button_url: @intake_link)

      %{args: args} = only_job()

      assert %{
               "email" => "aoife@example.com",
               "transactional_id" => "beginnersWorkshopAction",
               "subject" => "A place on Saturday 14 November 2026",
               "data_variables" => %{
                 "MESSAGE_HTML" => "<p>Hi Aoife, the fee is €50.00</p>",
                 "BUTTON_LABEL" => "Pay for your place"
               },
               "sealed_data_variables" => sealed
             } = args

      refute Jason.encode!(args) =~ "secret-intake-token"

      assert :ok = perform_job(Worker, args)

      assert_email_sent(fn email ->
        assert email.provider_options.template.id == "beginners-workshop-action"
        assert email.provider_options.template.variables["BUTTON_URL"] == @intake_link
        assert email.to == [{"", "aoife@example.com"}]
        assert email.reply_to == {"", "contact@dublinhemaclub.com"}
      end)

      assert is_binary(sealed)
    end

    test "each type uses its own button label" do
      for %{id: type, kind: :action, button_label: label} <- EmailType.all() do
        assert {:ok, %{args: %{"data_variables" => %{"BUTTON_LABEL" => ^label}}}} =
                 IntakeEmails.queue(type, @person, @values, button_url: @intake_link)
      end

      labels =
        all_enqueued(worker: Worker) |> Enum.map(& &1.args["data_variables"]["BUTTON_LABEL"])

      assert "Confirm my place" in labels
      assert "View my place" in labels
    end

    test "queues a notice email with no button and nothing sealed" do
      assert {:ok, _job} = IntakeEmails.queue("follow_up", @person, @values)

      %{args: args} = only_job()

      assert args["transactional_id"] == "beginnersWorkshopNotice"
      assert args["subject"] == "Thanks for coming on Saturday 14 November 2026"
      assert Map.keys(args["data_variables"]) == ["MESSAGE_HTML"]
      refute Map.has_key?(args, "sealed_data_variables")
    end

    test "substitutes the first name HTML-escaped" do
      values = %{@values | "firstName" => "<b>O'Brien</b>"}

      assert {:ok,
              %{args: %{"data_variables" => %{"MESSAGE_HTML" => html}, "subject" => subject}}} =
               IntakeEmails.queue("declined", @person, values)

      assert html =~ "Hi &lt;b&gt;O&#39;Brien&lt;/b&gt;,"
      refute html =~ "<b>"
      # The subject is a plain-text header, never HTML.
      assert subject == "We've kept your place in the queue"
    end

    test "fills the template current at queue time, so later edits don't change it" do
      assert {:ok, %{args: %{"data_variables" => %{"MESSAGE_HTML" => before}}}} =
               IntakeEmails.queue("deferred", @person, @values)

      {:ok, _} =
        IntakeEmails.update_template("deferred", %{body: doc([p([t("Edited")])])})

      assert [%{args: %{"data_variables" => %{"MESSAGE_HTML" => ^before}}}] =
               all_enqueued(worker: Worker)

      assert {:ok, %{args: %{"data_variables" => %{"MESSAGE_HTML" => "<p>Edited</p>"}}}} =
               IntakeEmails.queue("deferred", @person, @values)
    end

    test "refuses an action email without a button link" do
      assert {:error, :button_url_required} = IntakeEmails.queue("pre_workshop", @person, @values)
      refute_enqueued(worker: Worker)
    end

    test "refuses to render a blank for a missing value" do
      assert {:error, {:missing_values, ["refundAmount"]}} =
               IntakeEmails.queue(
                 "carried_fee_refunded",
                 @person,
                 Map.delete(@values, "refundAmount")
               )

      refute_enqueued(worker: Worker)
    end

    test "refuses a filled body over Resend's limit" do
      {:ok, _} =
        IntakeEmails.update_template("follow_up", %{
          body: doc([p(List.duplicate(ph("firstName"), 45))])
        })

      values = %{@values | "firstName" => String.duplicate("&", 40)}

      assert {:error, {:message_too_long, _length}} =
               IntakeEmails.queue("follow_up", @person, values)

      refute_enqueued(worker: Worker)
    end

    test "rolls back with the caller's transaction" do
      Repo.transaction(fn ->
        {:ok, _} = IntakeEmails.queue("follow_up", @person, @values)
        Repo.rollback(:command_refused)
      end)

      refute_enqueued(worker: Worker)
    end
  end

  describe "Values" do
    test "formats every value within its placeholder maximum" do
      maxima = EmailType.maxima()
      longest_date = ~D[2026-09-30]
      # 23:59 Dublin summer time on the longest date.
      deadline = ~U[2026-09-30 22:59:00Z]

      assert Values.date(longest_date) == "Wednesday 30 September 2026"
      assert String.length(Values.date(longest_date)) == maxima["date"]
      assert Values.deadline(deadline) == "Wednesday 30 September 2026, 23:59"
      assert String.length(Values.deadline(deadline)) == maxima["windowEnd"]
      assert String.length(Values.deadline(deadline)) == maxima["paymentCutoff"]
      assert Values.start_time(~T[09:05:00]) == "09:05"
      assert Values.money(5_000) == "€50.00"
      assert Values.money(99_999) == "€999.99"
      assert String.length(Values.money(99_999)) == maxima["fee"]
    end

    test "shows deadlines on the Dublin wall clock across daylight saving" do
      assert Values.deadline(~U[2026-11-08 23:59:00Z]) == "Sunday 8 November 2026, 23:59"
      assert Values.deadline(~U[2026-06-01 22:59:00Z]) == "Monday 1 June 2026, 23:59"
    end
  end
end
