defmodule Dhc.BeginnersWorkshops.IntakeEmails do
  @moduledoc """
  The delivery seam every Beginners' Workshop Intake Email goes through
  (ALE-377; ALE-374 "Intake Emails").

  An Intake Email is a club-wide template (`Template`: subject + Tiptap body,
  one row per `EmailType`) filled with one person's workshop details when it
  is **queued**, and sent as a Resend email of the type's Email Kind:

    * `beginnersWorkshopAction` (message + button) for open Intakes, with the
      type's fixed button label and the person's Intake link;
    * `beginnersWorkshopNotice` (message only) for closed Intakes.

  `queue/4` renders the body (`Renderer`: closed vocabulary, no inline styles,
  every text node and placeholder value HTML-escaped) and inserts one
  `Dhc.Email.Worker` job with:

    * `subject` — the filled template subject, overriding the Kind's default;
    * `data_variables` — `MESSAGE_HTML` (the first name is substituted into
      the body because Resend reserves `FIRST_NAME`) and, for action emails,
      `BUTTON_LABEL`;
    * `sealed_data_variables` — `BUTTON_URL`, the Intake link, which is a
      credential. These Kinds keep their seal for 24 hours.

  A template that passed the save-time measure always queues: should
  escaping push the filled body over Resend's limit, each value is
  shortened until its escaped HTML fits its placeholder maximum.

  Because the template is read and filled at queue time, a later edit
  affects only emails queued afterwards. Reply-To is the global contact
  address (`Dhc.Email.Worker`), and the recipient is always the person's own
  Waitlist email: Guardians have no email address in the system.

  ## Delivering an Intake Email (ALE-401)

  `deliver/5` owns everything after "this Intake is owed this email for this
  reason": the caller names the Intake (or, for the Waitlist tab, the
  person), the email, the `Occasion` and the clock reading — plus the
  refund for the four emails with `{{refundAmount}}` — and the module reads
  the recipient, the first name and the Payment Window itself, picks the
  Contact and Place-confirmed variants, fills every placeholder of the type
  from its one source, queues the job and writes the ledger row
  (`IntakeEmailLog`) in the caller's transaction, so a rolled-back command
  sends nothing. Only `Dhc.BeginnersWorkshops.Commands.*` may call it or
  `queue/4` (Reach): an Intake Email is never sent by anything else.

  `owing/1` and `scheduled/3` answer "who still owes it" for the sweep and
  the console from the same occasions.
  """

  import Ecto.Query
  require Dhc.BeginnersWorkshops.IntakeEmails.Occasion

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    CarriedFee,
    Clock,
    Intake,
    IntakeEmailLog,
    IntakeLink,
    WorkshopPolicy
  }

  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType
  alias Dhc.BeginnersWorkshops.IntakeEmails.Occasion
  alias Dhc.BeginnersWorkshops.IntakeEmails.Renderer
  alias Dhc.BeginnersWorkshops.IntakeEmails.Template
  alias Dhc.BeginnersWorkshops.IntakeEmails.Values
  alias Dhc.Email.RichText
  alias Dhc.Email.Worker
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @type queue_error ::
          Renderer.error()
          | :button_url_required
          | {:message_too_long, pos_integer()}
          | Ecto.Changeset.t()

  @typedoc """
  Who the email is about:

    * `{:intake, intake, workshop}` — the locked Intake and its locked
      workshop. The email goes to the Intake's person, with their Intake
      link as the button, and is logged on that Intake;
    * `{:person, entry, ledger_intake_id}` — the Waitlist tab's notices to a
      person with no open Intake (ALE-387/389). It is logged on
      `ledger_intake_id` (the Carried Fee's original Intake), or nowhere when
      `nil`; such notices name no workshop and carry no button.
  """
  @type about ::
          {:intake, Intake.t(), BeginnersWorkshop.t()}
          | {:person, WaitlistEntry.t() | nil, Ecto.UUID.t() | nil}

  @typedoc """
  The email: an exact `EmailType` id, or a variant the module picks —
  `:contact` (`contact_confirm` for a holder of a `held` Carried Fee, else
  `contact_pay`), `:place_confirmed` (`place_confirmed_carried` or
  `place_confirmed_paid` by the Intake's `paid_via`), or `:link` (the email
  an open Intake's link travels in: `:contact` while contacted,
  `:place_confirmed` once paid).
  """
  @type email :: :contact | :place_confirmed | :link | EmailType.id()

  @type result ::
          {:ok, :queued | :already_sent | :no_recipient}
          | {:error, :concurrent_change | queue_error()}

  @doc "Every template, in `EmailType.all/0` order."
  @spec list_templates() :: [Template.t()]
  def list_templates do
    by_type = Template |> Repo.all() |> Map.new(&{&1.email_type, &1})
    Enum.map(EmailType.ids(), &Map.fetch!(by_type, &1))
  end

  @spec get_template!(EmailType.id()) :: Template.t()
  def get_template!(type), do: Repo.get!(Template, type)

  @doc """
  Saves a type's subject and body (ALE-383). Only emails queued afterwards
  use the new copy: `queue/4` reads the template when it fills it.

  A refusal names its reason and carries the messages per field:

    * `:placeholder_not_allowed` — the subject or body uses a placeholder the
      type can't fill (including names outside the vocabulary);
    * `:template_too_long` — the body, with every placeholder at its longest,
      exceeds Resend's 2,000-character variable limit;
    * `:invalid_template` — anything else (a blank or multi-line subject, a
      body outside the rich-text vocabulary or without text).

  When several apply, the first in that order is the reason; every message
  is still reported. An id that is not an `EmailType` is
  `{:error, :unknown_email_type}`.
  """
  @spec update_template(term(), map()) ::
          {:ok, Template.t()}
          | {:error, :unknown_email_type}
          | {:error, Renderer.refusal(), %{(:subject | :body) => [String.t()]}}
  def update_template(type, attrs) when is_map(attrs) do
    case EmailType.fetch(type) do
      {:ok, _email_type} ->
        type
        |> get_template!()
        |> Template.changeset(attrs)
        |> Repo.update()
        |> refusal()

      :error ->
        {:error, :unknown_email_type}
    end
  end

  @refusal_precedence [:placeholder_not_allowed, :template_too_long, :invalid_template]

  defp refusal({:ok, _template} = ok), do: ok

  defp refusal({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    found = Enum.map(errors, fn {_field, {_message, opts}} -> opts[:refusal] end)
    reason = Enum.find(@refusal_precedence, :invalid_template, &(&1 in found))
    messages = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    {:error, reason, messages}
  end

  @doc """
  Queues the Intake Email `about` is owed for `occasion`, and writes its
  ledger row in the caller's transaction.

    * `{:ok, :queued}` — the job and (when there is an Intake to log it on)
      the ledger row are written;
    * `{:ok, :already_sent}` — an `:owed` occasion is already in the
      ledger, so nothing is written;
    * `{:ok, :no_recipient}` — the person is anonymised or has no email:
      nothing is written;
    * `{:error, :concurrent_change}` — an `:event` occasion is already in
      the ledger (a concurrent command sent it); roll back.

  `opts` takes `refund:` (an `IntakeRefund`) for the emails with a
  `{{refundAmount}}` placeholder.
  """
  @spec deliver(about(), email(), Occasion.t(), Clock.reading(), keyword()) :: result()
  def deliver(about, email, %Occasion{} = occasion, reading, opts \\ []) do
    with %WaitlistEntry{} = person <- recipient(about),
         :ok <- not_yet_owed(about, occasion) do
      type = pick(email, about, person)

      with {:ok, _job} <- queue(type, person, values(type, about, person, opts), button(about)),
           :ok <- log(ledger_intake_id(about), type, occasion, reading) do
        {:ok, :queued}
      end
    end
  end

  defp recipient({:intake, %Intake{waitlist_id: nil}, _workshop}), do: {:ok, :no_recipient}

  defp recipient({:intake, %Intake{waitlist_id: id}, _workshop}),
    do: WaitlistEntry |> Repo.get(id) |> addressed()

  defp recipient({:person, entry, _ledger_intake_id}), do: addressed(entry)

  defp addressed(%WaitlistEntry{email: email} = entry) when is_binary(email), do: entry
  defp addressed(_anonymised), do: {:ok, :no_recipient}

  # The ledger is the schedule: an owed occasion already logged is not owed.
  # Callers hold the workshop lock, which every writer of these occasions
  # takes; the unique index is the backstop.
  defp not_yet_owed(about, %Occasion{kind: :owed, name: name}) do
    case ledger_intake_id(about) do
      nil ->
        :ok

      intake_id ->
        logged? =
          Repo.exists?(
            from(l in IntakeEmailLog, where: l.intake_id == ^intake_id and l.occasion == ^name)
          )

        if logged?, do: {:ok, :already_sent}, else: :ok
    end
  end

  defp not_yet_owed(_about, %Occasion{kind: :event}), do: :ok

  defp pick(:link, {:intake, %Intake{state: "contacted"}, _w} = about, person),
    do: pick(:contact, about, person)

  defp pick(:link, {:intake, %Intake{state: "paid"}, _w} = about, person),
    do: pick(:place_confirmed, about, person)

  # A holder of a `held` Carried Fee is asked to confirm, not to pay
  # (ALE-388, story 60).
  defp pick(:contact, _about, %WaitlistEntry{id: id}) do
    held? =
      Repo.exists?(from(f in CarriedFee, where: f.waitlist_id == ^id and f.status == "held"))

    if held?, do: "contact_confirm", else: "contact_pay"
  end

  defp pick(:place_confirmed, {:intake, %Intake{paid_via: "carried_fee"}, _w}, _person),
    do: "place_confirmed_carried"

  defp pick(:place_confirmed, {:intake, %Intake{}, _w}, _person), do: "place_confirmed_paid"

  defp pick(type, _about, _person) when is_binary(type) do
    _known = EmailType.fetch!(type)
    type
  end

  # One source per placeholder, for exactly the type's placeholders.
  defp values(type, about, person, opts) do
    first_name = first_name(person)

    Map.new(EmailType.fetch!(type).placeholders, fn name ->
      {name, value(name, about, first_name, opts)}
    end)
  end

  defp value("firstName", _about, first_name, _opts), do: first_name
  defp value("date", {:intake, _i, workshop}, _name, _opts), do: Values.date(workshop.date)

  defp value("startTime", {:intake, _i, workshop}, _name, _opts),
    do: Values.start_time(workshop.start_time)

  defp value("venue", {:intake, _i, workshop}, _name, _opts), do: workshop.venue
  defp value("fee", {:intake, _i, workshop}, _name, _opts), do: Values.money(workshop.fee_cents)

  defp value("paymentCutoff", {:intake, _i, workshop}, _name, _opts),
    do: Values.deadline(workshop.payment_cutoff)

  defp value("windowEnd", {:intake, intake, workshop}, _name, _opts),
    do: Values.deadline(payment_window_end(intake, workshop))

  defp value("refundAmount", _about, _name, opts),
    do: opts |> Keyword.fetch!(:refund) |> Values.refund_amount()

  defp first_name(%WaitlistEntry{id: id}) do
    Repo.one(from(p in UserProfile, where: p.waitlist_id == ^id, limit: 1, select: p.first_name)) ||
      ""
  end

  # The Intake's Payment Window: its Batch window, else
  # `WorkshopPolicy.payment_window_end/3`'s rule.
  defp payment_window_end(%Intake{} = intake, workshop),
    do: WorkshopPolicy.payment_window_end(workshop, batch_window_end(intake), intake.contacted_at)

  defp batch_window_end(%Intake{batch_id: nil}), do: nil

  defp batch_window_end(%Intake{batch_id: batch_id}),
    do: Repo.one!(from(b in Batch, where: b.id == ^batch_id, select: b.window_ends_at))

  defp button({:intake, %Intake{} = intake, _workshop}),
    do: [button_url: IntakeLink.url(IntakeLink.token(intake.id, intake.link_generation))]

  defp button({:person, _entry, _ledger_intake_id}), do: []

  defp ledger_intake_id({:intake, %Intake{id: id}, _workshop}), do: id
  defp ledger_intake_id({:person, _entry, ledger_intake_id}), do: ledger_intake_id

  defp log(nil, _type, _occasion, _reading), do: :ok

  defp log(intake_id, type, %Occasion{name: name}, reading) do
    %{intake_id: intake_id, email_type: type, occasion: name, queued_at: reading.now}
    |> IntakeEmailLog.changeset()
    |> Repo.insert()
    |> case do
      {:ok, _log} -> :ok
      {:error, changeset} -> {:error, log_refusal(changeset)}
    end
  end

  # The occasion's unique index: a concurrent command logged it first.
  defp log_refusal(%Ecto.Changeset{errors: errors} = changeset) do
    if Enum.any?(errors, fn {_field, {_message, meta}} -> meta[:constraint] == :unique end),
      do: :concurrent_change,
      else: changeset
  end

  @doc """
  Intakes that still owe `occasion` now (no workshop or clock filter: the
  pass judges those under its lock): a `paid` Intake its Pre-workshop info
  for the workshop's current schedule, an `attended` one its Follow-up.
  An anonymised person is owed nothing. The Intake binding is `:intake`.
  """
  @spec owing(:pre_workshop | :follow_up) :: Ecto.Query.t()
  def owing(:pre_workshop) do
    from(i in Intake,
      as: :intake,
      join: w in BeginnersWorkshop,
      on: w.id == i.workshop_id,
      left_join: l in IntakeEmailLog,
      on: l.intake_id == i.id and l.occasion == Occasion.pre_workshop_sql(w.reschedule_count),
      where: i.state == "paid" and not is_nil(i.waitlist_id) and is_nil(l.id)
    )
  end

  def owing(:follow_up) do
    follow_up = Occasion.follow_up().name

    from(i in Intake,
      as: :intake,
      left_join: l in IntakeEmailLog,
      on: l.intake_id == i.id and l.occasion == ^follow_up,
      where: i.state == "attended" and not is_nil(i.waitlist_id) and is_nil(l.id)
    )
  end

  @doc """
  The scheduled email an Intake in `intake_state` still owes, given the
  occasions already `logged` for it: Pre-workshop info for this schedule to
  a `paid` Intake of a scheduled workshop, at the Payment Cutoff, and the
  Follow-up to an `attended` Intake of a finalised one, at
  `WorkshopPolicy.follow_up_at/1`. An `at` in the past means the next sweep.
  """
  @spec scheduled(String.t(), [String.t()], BeginnersWorkshop.t()) :: [
          %{email_type: EmailType.id(), at: DateTime.t()}
        ]
  def scheduled("paid", logged, %BeginnersWorkshop{status: "scheduled"} = workshop),
    do:
      unless_logged(
        logged,
        Occasion.pre_workshop(workshop.reschedule_count),
        "pre_workshop",
        workshop.payment_cutoff
      )

  def scheduled("attended", logged, %BeginnersWorkshop{status: "finalised"} = workshop),
    do:
      unless_logged(
        logged,
        Occasion.follow_up(),
        "follow_up",
        WorkshopPolicy.follow_up_at(workshop)
      )

  def scheduled(_state, _logged, _workshop), do: []

  defp unless_logged(logged, %Occasion{name: name}, email_type, at) do
    if name in logged, do: [], else: [%{email_type: email_type, at: at}]
  end

  @doc """
  Fills the type's current template for one person and queues it. Used by
  `deliver/5`, which writes the ledger row and picks the values.

  `values` maps placeholder names (`"firstName"`, `"date"`, …) to formatted
  strings and must cover every placeholder the template uses. Action types
  require `button_url:` (the person's Intake link).
  """
  @spec queue(EmailType.id(), WaitlistEntry.t(), Renderer.values(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, queue_error()}
  def queue(type, %WaitlistEntry{email: email}, values, opts \\ []) when is_binary(email) do
    email_type = EmailType.fetch!(type)
    template = get_template!(type)

    with {:ok, button} <- button(email_type, opts),
         {:ok, subject} <- Renderer.render_subject(type, template.subject, values),
         {:ok, html} <- render_within_limit(type, template.body, values) do
      # String keys, so the returned job's args read like the stored ones.
      %{
        "email" => email,
        "transactional_id" => EmailType.email_kind(email_type),
        "subject" => subject,
        "data_variables" => Map.merge(%{"MESSAGE_HTML" => html}, button.plain)
      }
      |> put_sealed(button.sealed)
      |> Worker.new()
      |> Oban.insert()
    end
  end

  defp button(%{kind: :notice}, _opts), do: {:ok, %{plain: %{}, sealed: nil}}

  defp button(%{kind: :action, button_label: label}, opts) do
    case Keyword.get(opts, :button_url) do
      url when is_binary(url) and url != "" ->
        {:ok, %{plain: %{"BUTTON_LABEL" => label}, sealed: %{"BUTTON_URL" => url}}}

      _missing ->
        {:error, :button_url_required}
    end
  end

  # A saved template fits Resend's limit with every placeholder filled by
  # `"x"` at its maximum length (the save-time measure). A real value is
  # HTML-escaped, so one with `&`, `<`, `>`, `"` or `'` can render longer
  # than its maximum (`'` → `&#39;`). Only when the filled body is then over
  # the limit is each value shortened until its *escaped* form fits its
  # maximum, which keeps the body within the save-time measure: queueing
  # never refuses a template that passed it. `{:message_too_long, _}` is
  # left only for a template that never went through the measure.
  defp render_within_limit(type, body, values) do
    with {:ok, html} <- Renderer.render_body(type, body, values) do
      if Renderer.utf16_length(html) <= Renderer.limit(),
        do: {:ok, html},
        else: render_fitted(type, body, values)
    end
  end

  defp render_fitted(type, body, values) do
    with {:ok, html} <- Renderer.render_body(type, body, fit_values(values)),
         :ok <- within_limit(html),
         do: {:ok, html}
  end

  defp fit_values(values) do
    maxima = EmailType.maxima()
    Map.new(values, fn {name, value} -> {name, fit(value, Map.get(maxima, name))} end)
  end

  defp fit(value, nil), do: value

  defp fit(value, max) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {kept, length} ->
      length = length + Renderer.utf16_length(RichText.escape(grapheme))
      if length <= max, do: {:cont, {kept <> grapheme, length}}, else: {:halt, {kept, length}}
    end)
    |> elem(0)
  end

  defp within_limit(html) do
    length = Renderer.utf16_length(html)

    if length > Renderer.limit(), do: {:error, {:message_too_long, length}}, else: :ok
  end

  defp put_sealed(args, nil), do: args

  defp put_sealed(args, sealed),
    do: Map.put(args, "sealed_data_variables", Worker.seal_data_variables(sealed))
end
