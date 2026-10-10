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

  Because the template is read and filled at queue time, a later edit
  affects only emails queued afterwards. Call `queue/4` inside the
  transaction of the transition that causes the email, so a rolled-back
  command sends nothing. Reply-To is the global contact address
  (`Dhc.Email.Worker`), and the recipient is always the person's own Waitlist
  email: Guardians have no email address in the system.

  For a fast-track (no Batch), pass the Payment Cutoff as `windowEnd`.
  Format values with `Values`.
  """

  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType
  alias Dhc.BeginnersWorkshops.IntakeEmails.Renderer
  alias Dhc.BeginnersWorkshops.IntakeEmails.Template
  alias Dhc.Email.Worker
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  @type queue_error ::
          Renderer.error()
          | :button_url_required
          | {:message_too_long, pos_integer()}
          | Ecto.Changeset.t()

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
  Fills the type's current template for one person and queues it.

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
         {:ok, html} <- Renderer.render_body(type, template.body, values),
         :ok <- within_limit(html) do
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

  # A saved template always fits with values at their maxima; this guards a
  # value that was not validated to its maximum, which Resend would reject.
  defp within_limit(html) do
    length = Renderer.utf16_length(html)

    if length > Renderer.limit(), do: {:error, {:message_too_long, length}}, else: :ok
  end

  defp put_sealed(args, nil), do: args

  defp put_sealed(args, sealed),
    do: Map.put(args, "sealed_data_variables", Worker.seal_data_variables(sealed))
end
