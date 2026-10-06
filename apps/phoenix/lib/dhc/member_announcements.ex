defmodule Dhc.MemberAnnouncements do
  @moduledoc """
  Member Announcements: a committee email sent to many members at once
  (ADR 0028).

  The committee writes a subject and a rich-text body (a Tiptap JSON
  document) and chooses the audience — active members by default, optionally
  inactive members too. Three operations:

    * `preview/1` renders exactly the email that would be sent and counts its
      recipients, without writing anything. The dashboard's live preview is
      this render, so the preview cannot disagree with the email.
    * `send_announcement/2` validates, renders, freezes the recipient
      addresses, and inserts the row and its delivery job in one transaction.
    * `list_recent/1` reads the latest sends with their delivery status.

  Delivery is `Dhc.MemberAnnouncements.Delivery` behind
  `Workers.DeliveryWorker`: recipients are BCC'd in groups and every group
  goes out in one Resend batch request.

  **Audience.** A recipient is a Member — a Principal with a member profile
  and a user profile — whose user profile `is_active` (paused memberships
  count as active), or any such Member when inactive members are included.
  Waitlist entries and Invitations are never recipients. Addresses are
  de-duplicated case-insensitively.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Dhc.Auth.Principal
  alias Dhc.MemberAnnouncements.Announcement
  alias Dhc.MemberAnnouncements.Document
  alias Dhc.MemberAnnouncements.Shell
  alias Dhc.MemberAnnouncements.Workers.DeliveryWorker
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @max_subject_length 200

  @types %{subject: :string, body: :map, include_inactive: :boolean}

  @type draft :: %{subject: String.t(), body: map(), include_inactive: boolean()}
  @type preview :: %{html: String.t(), text: String.t(), recipient_count: non_neg_integer()}

  @doc """
  Renders the email for `params` (`"subject"`, `"body"`, `"includeInactive"`)
  and counts who would receive it. Writes nothing.
  """
  @spec preview(map()) :: {:ok, preview()} | {:error, Ecto.Changeset.t()}
  def preview(params) when is_map(params) do
    with {:ok, draft, rendered} <- validate(params) do
      {:ok,
       %{
         html: Shell.render(draft.subject, rendered.html),
         text: rendered.text,
         recipient_count: recipient_count(draft.include_inactive)
       }}
    end
  end

  @doc """
  Records a Member Announcement sent by `principal_id` and enqueues its
  delivery. Returns `{:error, :no_recipients}` when the audience is empty.
  """
  @spec send_announcement(Ecto.UUID.t(), map()) ::
          {:ok, Announcement.t()} | {:error, Ecto.Changeset.t() | :no_recipients}
  def send_announcement(principal_id, params) when is_binary(principal_id) and is_map(params) do
    with {:ok, draft, rendered} <- validate(params),
         [_ | _] = emails <- recipient_emails(draft.include_inactive) do
      announcement = %Announcement{
        subject: draft.subject,
        body: draft.body,
        email_html: Shell.render(draft.subject, rendered.html),
        email_text: rendered.text,
        include_inactive: draft.include_inactive,
        recipient_emails: emails,
        recipient_count: length(emails),
        sent_by_principal_id: principal_id
      }

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:announcement, announcement)
      |> Oban.insert(:job, fn %{announcement: %{id: id}} ->
        DeliveryWorker.new(%{"announcement_id" => id})
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{announcement: announcement}} -> {:ok, announcement}
        {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      end
    else
      [] -> {:error, :no_recipients}
      {:error, _} = error -> error
    end
  end

  @doc """
  The latest Member Announcements, newest first, each with the sender's
  display name (`sent_by_name`, `nil` when the profile is gone).
  """
  @spec list_recent(pos_integer()) :: [
          %{announcement: Announcement.t(), sent_by_name: String.t() | nil}
        ]
  def list_recent(limit \\ 20) when is_integer(limit) and limit > 0 do
    from(a in Announcement,
      left_join: up in UserProfile,
      on: up.principal_id == a.sent_by_principal_id,
      order_by: [desc: a.created_at, desc: a.id],
      limit: ^limit,
      select: %{
        announcement: a,
        sent_by_name: fragment("NULLIF(TRIM(CONCAT(?, ' ', ?)), '')", up.first_name, up.last_name)
      }
    )
    |> Repo.all()
  end

  @doc "Fetches one announcement by id."
  @spec get(Ecto.UUID.t()) :: Announcement.t() | nil
  def get(id), do: Repo.get(Announcement, id)

  @doc """
  The de-duplicated, lower-cased recipient addresses of the audience,
  sorted so a frozen list is deterministic.
  """
  @spec recipient_emails(boolean()) :: [String.t()]
  def recipient_emails(include_inactive) when is_boolean(include_inactive) do
    include_inactive
    |> audience()
    |> select([_up, p], fragment("lower(?)", p.email))
    |> distinct(true)
    |> order_by([_up, p], fragment("lower(?)", p.email))
    |> Repo.all()
  end

  @spec recipient_count(boolean()) :: non_neg_integer()
  def recipient_count(include_inactive) when is_boolean(include_inactive) do
    include_inactive
    |> audience()
    |> select([_up, p], count(fragment("DISTINCT lower(?)", p.email)))
    |> Repo.one()
  end

  defp audience(include_inactive) do
    query =
      from(up in UserProfile,
        join: p in Principal,
        on: p.id == up.principal_id,
        join: mp in MemberProfile,
        on: mp.id == p.id,
        where: not is_nil(p.email) and p.email != ""
      )

    if include_inactive, do: query, else: where(query, [up], up.is_active == true)
  end

  # ── Validation ───────────────────────────────────────────────────────

  defp validate(params) do
    changeset =
      {%{include_inactive: false}, @types}
      |> cast(normalize(params), Map.keys(@types))
      |> update_change(:subject, &String.trim/1)
      |> validate_required([:subject], message: "can't be blank")
      |> validate_length(:subject, max: @max_subject_length)
      |> validate_change(:subject, fn :subject, subject ->
        if String.contains?(subject, ["\r", "\n"]),
          do: [subject: "must be a single line"],
          else: []
      end)
      |> validate_required([:body], message: "can't be blank")

    {changeset, rendered} = render_body(changeset)

    with {:ok, draft} <- apply_action(changeset, :validate) do
      {:ok, Map.update(draft, :include_inactive, false, &(&1 == true)), rendered}
    end
  end

  # The body is rendered even when other fields are invalid, so one response
  # names every problem.
  defp render_body(changeset) do
    case get_change(changeset, :body) do
      nil ->
        {changeset, nil}

      body ->
        case Document.render(body) do
          {:ok, rendered} -> {changeset, rendered}
          {:error, message} -> {add_error(changeset, :body, message), nil}
        end
    end
  end

  # The wire names are camelCase; only the known keys are cast.
  defp normalize(params) do
    params
    |> Map.take(["subject", "body", "includeInactive"])
    |> Enum.into(%{}, fn
      {"includeInactive", value} -> {"include_inactive", value}
      pair -> pair
    end)
  end
end
