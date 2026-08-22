defmodule Dhc.Invitations do
  @moduledoc """
  Invitation context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.DiscordSubjectLock
  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Email.Worker, as: EmailWorker
  alias Dhc.Auth.UserRole
  alias Dhc.CursorPagination
  alias Dhc.Discord.JoinGrant
  alias Dhc.Discord.Workers.GuildJoinWorker
  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.Repository
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @invite_email_template "inviteMember"
  @verification_token_max_age_seconds 15 * 60

  # ── List (cursor pagination) ─────────────────────────────────────────
  # The dashboard invitations table reads only `pending` and `expired` rows,
  # mirroring the previous hardcoded client filter. There is no `status`
  # query param — `accepted`/`revoked` rows are never returned — but the
  # `status` field is still present in the DTO for badge rendering.
  @allowed_limits [10, 25, 50, 100]
  @allowed_sort_fields ~w(email status expiresAt createdAt)
  @allowed_directions ~w(asc desc)
  @visible_statuses ~w(pending expired)
  @list_sort_specs %{
    "email" => %{field: :email},
    "status" => %{field: :status},
    "expiresAt" => %{field: :expires_at, type: :utc_datetime, encode: &DateTime.to_iso8601/1},
    "createdAt" => %{field: :created_at, type: :utc_datetime, encode: &DateTime.to_iso8601/1}
  }

  @doc """
  Returns cursor-paginated, domain-shaped member invitations for the dashboard.

  The server always filters to `pending` and `expired` invitations. Cursor
  payloads bind to the query semantics (limit, search, sort and direction),
  so stale cursors from a different table state return an explicit
  `{:error, :bad_cursor}` instead of silently serving the wrong page.

  `totalCount` is an exact `COUNT(*)`, not an estimated count, replacing the
  prior client-side estimated count.
  """
  @spec list(map()) :: {:ok, map()} | {:error, atom()}
  def list(params \\ %{}) do
    with {:ok, opts} <- parse_list_options(params),
         {:ok, cursor} <- CursorPagination.parse_cursor(opts, &list_cursor_context/1) do
      total_count = list_total_count(opts)
      rows = list_rows(opts, cursor)

      page =
        CursorPagination.page(rows, opts, cursor, &list_cursor_context/1, &list_cursor_value/2)

      {:ok,
       %{
         invitations: page.visible_rows,
         total_count: total_count,
         limit: opts.limit,
         next_cursor: page.next_cursor,
         previous_cursor: page.previous_cursor
       }}
    end
  end

  @doc """
  Returns public-safe Invitation state for the signup flow.

  This intentionally excludes PII such as email, date of birth, and names.
  """
  @spec public_lookup(String.t()) :: {:ok, Invitation.t()} | {:error, :not_found}
  def public_lookup(id) when is_binary(id) do
    case Repo.get(Invitation, id) do
      nil -> {:error, :not_found}
      invitation -> {:ok, invitation}
    end
  end

  @doc """
  Verifies public Invitation credentials without issuing bearer material.
  """
  @spec verify_credentials(String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_credentials}
  def verify_credentials(invitation_id, email, date_of_birth) do
    with {:ok, date} <- parse_date(date_of_birth),
         true <- credentials_match?(invitation_id, email, date) do
      :ok
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  @doc """
  Issues a legacy opaque signed token for compatibility and rejection tests.
  """
  @spec issue_verification_token(String.t(), String.t(), Date.t()) :: {:ok, String.t()}
  def issue_verification_token(invitation_id, email, %Date{} = date_of_birth) do
    token =
      Phoenix.Token.sign(DhcWeb.Endpoint, verification_token_salt(), %{
        "invitation_id" => invitation_id,
        "email" => normalize_email(email),
        "date_of_birth" => Date.to_iso8601(date_of_birth)
      })

    {:ok, token}
  end

  @doc false
  def verify_acceptance_token(token, invitation_id) do
    with {:ok, claims} <- verify_token(token),
         do: token_matches_invitation(claims, invitation_id)
  end

  @doc false
  def convert(
        invitation_id,
        attempt_id,
        next_of_kin_name,
        next_of_kin_phone,
        customer_id
      ) do
    do_convert(
      invitation_id,
      attempt_id,
      next_of_kin_name,
      next_of_kin_phone,
      customer_id,
      nil,
      nil
    )
  end

  @doc false
  def convert(
        invitation_id,
        attempt_id,
        continuation_id,
        next_of_kin_name,
        next_of_kin_phone,
        customer_id
      ) do
    do_convert(
      invitation_id,
      attempt_id,
      next_of_kin_name,
      next_of_kin_phone,
      customer_id,
      continuation_id,
      nil
    )
  end

  @doc false
  def convert_with_discord(
        invitation_id,
        attempt_id,
        continuation_id,
        next_of_kin_name,
        next_of_kin_phone,
        customer_id,
        operation_token
      ) do
    do_convert(
      invitation_id,
      attempt_id,
      next_of_kin_name,
      next_of_kin_phone,
      customer_id,
      continuation_id,
      operation_token
    )
  end

  defp do_convert(
         invitation_id,
         attempt_id,
         next_of_kin_name,
         next_of_kin_phone,
         customer_id,
         continuation_id,
         operation_token
       ) do
    Repo.transaction(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      lock_discord_conversion_advisories!(invitation_id, continuation_id)

      invitation = lock_pending_invitation!(invitation_id)
      attempt = lock_provisioned_attempt!(attempt_id, invitation.id, operation_token)

      discord =
        lock_discord_conversion!(
          continuation_id,
          invitation,
          attempt
        )

      ensure_member_absent!(invitation.prospective_principal_id)
      register_principal!(invitation)

      user_profile_id = reuse_or_create_user_profile(invitation, customer_id, now)

      member_profile = %MemberProfile{
        id: invitation.prospective_principal_id,
        user_profile_id: user_profile_id,
        next_of_kin_name: next_of_kin_name,
        next_of_kin_phone: next_of_kin_phone,
        preferred_weapon: [],
        membership_start_date: now,
        insurance_form_submitted: true,
        additional_data: %{}
      }

      insert_member_profile!(member_profile)
      maybe_create_discord_identity(discord, invitation.prospective_principal_id)

      invitation |> Ecto.Changeset.change(status: "accepted") |> Repo.update!()

      Repo.insert_all(
        UserRole,
        [[principal_id: invitation.prospective_principal_id, role: "member"]],
        on_conflict: :nothing,
        conflict_target: [:principal_id, :role]
      )

      waitlist_query = waitlist_entry_query(invitation)

      Repo.update_all(waitlist_query, set: [status: "joined", last_status_change: now])

      from(a in InvitationAcceptanceAttempt,
        where: a.id == ^attempt_id and a.invitation_id == ^invitation.id
      )
      |> Repo.update_all(
        set: [
          status: "completed",
          concluded_at: now,
          updated_at: now,
          last_error: nil,
          acceptance_data: clear_payment_secrets(attempt.acceptance_data),
          operation_token: nil,
          operation_started_at: nil
        ]
      )

      maybe_consume_discord(discord, now)
      maybe_enqueue_guild_join(continuation_id)

      %{member_id: invitation.prospective_principal_id}
    end)
  end

  defp lock_pending_invitation!(invitation_id) do
    invitation =
      from(i in Invitation,
        where: i.id == ^invitation_id and i.status == "pending",
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    if is_nil(invitation), do: Repo.rollback(:invalid_invitation), else: invitation
  end

  defp lock_provisioned_attempt!(attempt_id, invitation_id, operation_token) do
    query =
      from(a in InvitationAcceptanceAttempt,
        where:
          a.id == ^attempt_id and a.invitation_id == ^invitation_id and
            a.status == "provisioned"
      )
      |> maybe_require_operation_token(operation_token)

    attempt = from(a in query, lock: "FOR UPDATE") |> Repo.one()

    if is_nil(attempt), do: Repo.rollback(:invalid_attempt), else: attempt
  end

  defp maybe_require_operation_token(query, nil), do: query

  defp maybe_require_operation_token(query, operation_token),
    do: from(a in query, where: a.operation_token == ^operation_token)

  defp ensure_member_absent!(principal_id) do
    if Repo.exists?(from(m in MemberProfile, where: m.id == ^principal_id)),
      do: Repo.rollback(:invalid_invitation)
  end

  defp register_principal!(invitation) do
    case Auth.register_principal_with_id(invitation.prospective_principal_id, %{
           email: invitation.email
         }) do
      {:ok, _principal} -> :ok
      {:error, _changeset} -> Repo.rollback(:principal_creation_failed)
    end
  end

  defp insert_member_profile!(member_profile) do
    case Repo.insert(member_profile) do
      {:ok, _member_profile} -> :ok
      {:error, _changeset} -> Repo.rollback(:invalid_invitation)
    end
  end

  defp maybe_create_discord_identity(nil, _principal_id), do: :ok

  defp maybe_create_discord_identity(discord, principal_id) do
    principal = Repo.get!(Dhc.Auth.Principal, principal_id)

    metadata =
      discord.continuation.display_metadata
      |> Map.take(["username", "avatarUrl"])
      |> rename_avatar_metadata()

    %ExternalIdentity{}
    |> ExternalIdentity.create_changeset(principal, %{
      provider: "discord",
      provider_subject: discord.continuation.provider_subject,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp waitlist_entry_query(%Invitation{waitlist_id: waitlist_id}) when not is_nil(waitlist_id),
    do: from(w in WaitlistEntry, where: w.id == ^waitlist_id)

  defp waitlist_entry_query(%Invitation{email: email}),
    do: from(w in WaitlistEntry, where: w.email == ^email)

  defp maybe_consume_discord(nil, _now), do: :ok

  defp maybe_consume_discord(discord, now) do
    Repo.delete!(discord.claim)

    discord.continuation
    |> Ecto.Changeset.change(
      status: "consumed",
      concluded_at: now,
      provider_subject: nil,
      display_metadata: %{}
    )
    |> Repo.update!()
  end

  defp maybe_enqueue_guild_join(nil), do: :ok

  defp maybe_enqueue_guild_join(continuation_id) do
    case Repo.get_by(JoinGrant, continuation_id: continuation_id) do
      nil -> :ok
      grant -> Oban.insert!(GuildJoinWorker.new(%{"grant_id" => grant.id}))
    end
  end

  defp lock_discord_conversion!(nil, _invitation, _attempt), do: nil

  defp lock_discord_conversion!(continuation_id, invitation, attempt) do
    continuation =
      from(c in InvitationAcceptanceDiscordContinuation,
        where:
          c.id == ^continuation_id and c.invitation_id == ^invitation.id and
            c.attempt_id == ^attempt.id and c.status == "verified",
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    if is_nil(continuation), do: Repo.rollback(:invalid_continuation)

    claim =
      from(c in InvitationAcceptanceDiscordSubjectClaim,
        where:
          c.continuation_id == ^continuation.id and c.provider == "discord" and
            c.provider_subject == ^continuation.provider_subject,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    if is_nil(claim), do: Repo.rollback(:invalid_continuation)

    %{continuation: continuation, claim: claim}
  end

  defp lock_discord_conversion_advisories!(_invitation_id, nil), do: :ok

  defp lock_discord_conversion_advisories!(invitation_id, continuation_id) do
    invitation = Repo.get(Invitation, invitation_id)

    if is_nil(invitation), do: Repo.rollback(:invalid_invitation)

    DiscordSubjectLock.lock_principal!(invitation.prospective_principal_id)

    continuation = Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id)

    if is_nil(continuation) or is_nil(continuation.provider_subject),
      do: Repo.rollback(:invalid_continuation)

    DiscordSubjectLock.lock!(continuation.provider_subject)
  end

  defp rename_avatar_metadata(%{"avatarUrl" => avatar_url} = metadata) do
    metadata |> Map.delete("avatarUrl") |> Map.put("avatar", avatar_url)
  end

  defp rename_avatar_metadata(metadata), do: metadata

  defp clear_payment_secrets(data) when is_map(data), do: Map.delete(data, "payment")

  # ALE-176: resolve the UserProfile acceptance leaves behind. When the
  # invitation came from a waitlist entry, lock the existing waitlist
  # UserProfile `FOR UPDATE` and reuse it — setting `principal_id`,
  # `is_active`, and `customer_id` while preserving the intake-captured
  # fields (first/last/DOB/gender/pronouns/phone/social_media_consent/
  # medical_conditions) and the guardian linkage. When there is no
  # waitlist profile to reuse (direct invite without a `waitlist_id`, or the
  # intake row was never created), acceptance materializes a fresh
  # UserProfile from the invitation row, matching the pre-ALE-176 behavior.
  #
  # The `FOR UPDATE` lock serializes a concurrent second acceptance of a
  # sibling invitation tied to the same waitlist_id (the partial unique on
  # `user_profiles(waitlist_id)` would otherwise reject the loser's insert
  # with a constraint error; locking lets us update in place).
  defp reuse_or_create_user_profile(invitation, customer_id, now) do
    waitlist_profile =
      if invitation.waitlist_id do
        from(up in UserProfile,
          where: up.waitlist_id == ^invitation.waitlist_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()
      else
        nil
      end

    if waitlist_profile do
      waitlist_profile
      |> Ecto.Changeset.change(
        principal_id: invitation.prospective_principal_id,
        is_active: true,
        customer_id: customer_id,
        updated_at: now
      )
      |> Repo.update!()

      waitlist_profile.id
    else
      user_profile = %UserProfile{
        id: Ecto.UUID.generate(),
        principal_id: invitation.prospective_principal_id,
        first_name: invitation.first_name,
        last_name: invitation.last_name,
        phone_number: invitation.phone_number,
        date_of_birth: invitation.date_of_birth,
        customer_id: customer_id,
        is_active: true,
        waitlist_id: invitation.waitlist_id,
        social_media_consent: "no"
      }

      case Repo.insert(user_profile) do
        {:ok, profile} -> profile.id
        {:error, _changeset} -> Repo.rollback(:invalid_invitation)
      end
    end
  end

  @doc """
  Re-enqueues invite-member emails for existing invitations.

  Only actionable invitations (`pending` / `expired`) are considered; one
  email per address, targeting the most recent actionable invitation.
  Accepted and revoked invitations are never resurrected, and sibling rows
  for the same email keep their status, so a resend can never create a
  second pending invitation for an email.
  """
  @spec resend_invitation_emails([String.t()]) ::
          {:ok, %{succeeded: non_neg_integer(), failed: non_neg_integer()}}
  def resend_invitation_emails([_ | _] = raw_emails) do
    emails = Enum.uniq(raw_emails)
    invite_data = list_invitation_resend_data(emails)

    succeeded =
      invite_data
      |> Enum.map(fn invitation ->
        with :ok <- enqueue_invitation_email(invitation),
             :ok <- refresh_for_resend(invitation.id) do
          :ok
        else
          {:error, _reason} -> {:error, invitation.email}
        end
      end)
      |> Enum.count(&match?(:ok, &1))

    {:ok, %{succeeded: succeeded, failed: length(emails) - succeeded}}
  end

  def resend_invitation_emails(_emails), do: {:ok, %{succeeded: 0, failed: 0}}

  @doc """
  Permanently deletes the requested Invitations.

  Missing ids are ignored to preserve the previous bulk-delete semantics.
  """
  @spec delete_many([String.t()]) :: :ok | {:error, :invalid_invitation_ids}
  def delete_many(invitation_ids) when is_list(invitation_ids) and invitation_ids != [] do
    if Enum.all?(invitation_ids, &valid_uuid?/1) do
      from(i in Invitation, where: i.id in ^invitation_ids)
      |> Repo.delete_all()

      :ok
    else
      {:error, :invalid_invitation_ids}
    end
  end

  def delete_many(_invitation_ids), do: {:error, :invalid_invitation_ids}

  defp credentials_match?(invitation_id, email, %Date{} = date_of_birth) do
    normalized_email = normalize_email(email)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # ALE-162: date_of_birth is now stored on the invitation row at issue
    # time (no user_profiles row exists until acceptance). Match email + DOB
    # directly on the invitation.
    query =
      from i in Invitation,
        left_join: a in InvitationAcceptanceAttempt,
        on:
          a.invitation_id == i.id and
            a.status in ["processing", "payment_pending", "provisioned"],
        where: i.id == ^invitation_id,
        where: fragment("lower(?)", i.email) == ^normalized_email,
        where: i.status == "pending",
        where: i.expires_at > ^now or not is_nil(a.id),
        where: i.date_of_birth == ^date_of_birth,
        distinct: true,
        select: i.id

    Repo.exists?(query)
  end

  defp verify_token(token) when is_binary(token) do
    Phoenix.Token.verify(DhcWeb.Endpoint, verification_token_salt(), token,
      max_age: @verification_token_max_age_seconds
    )
    |> case do
      {:ok, claims} -> {:ok, claims}
      {:error, _reason} -> {:error, :invalid_token}
    end
  end

  defp verify_token(_token), do: {:error, :invalid_token}

  defp verification_token_salt do
    Application.fetch_env!(:dhc, :invitation_verification_token_salt)
  end

  defp token_matches_invitation(%{"invitation_id" => invitation_id}, invitation_id), do: :ok
  defp token_matches_invitation(_claims, _invitation_id), do: {:error, :invalid_token}

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    value
    |> String.split("T")
    |> List.first()
    |> Date.from_iso8601()
  end

  defp parse_date(_value), do: {:error, :invalid_date}

  defp list_invitation_resend_data(emails) do
    # ALE-162: first_name / last_name / date_of_birth now live on the
    # invitation row (carried at issue time). The pre-ALE-162 left-join to
    # user_profiles is gone — there is no user_profiles row to join to
    # until acceptance.
    #
    # Only `pending` / `expired` rows are actionable for resend. An email can
    # legitimately have several historical rows (e.g. an expired invitation
    # plus the current pending one), so pick the newest per email and leave
    # the older rows untouched.
    from(i in Invitation,
      where: i.email in ^emails and i.status in ["pending", "expired"],
      order_by: [desc: i.created_at],
      select: %{
        id: i.id,
        email: i.email,
        first_name: i.first_name,
        last_name: i.last_name,
        date_of_birth: i.date_of_birth
      }
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.email)
  end

  defp enqueue_invitation_email(invitation) do
    args = %{
      "email" => invitation.email,
      "transactional_id" => @invite_email_template,
      "data_variables" => %{
        "INVITEE_FIRST_NAME" => invitation.first_name || "",
        "INVITEE_LAST_NAME" => invitation.last_name || "",
        "INVITATION_LINK" => invitation_link(invitation)
      }
    }

    case Oban.insert(EmailWorker.new(args)) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Re-arms exactly the invitation being resent: pending again with a fresh
  # short expiry window. Targeted by id (not by email), so sibling rows for
  # the same email are never flipped to pending — flipping more than one row
  # would violate `invitations_email_pending_unique`, and flipping an
  # accepted/revoked row would resurrect a settled invitation.
  defp refresh_for_resend(invitation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(i in Invitation,
      where: i.id == ^invitation_id and i.status in ["pending", "expired"]
    )
    |> Repo.update_all(
      set: [status: "pending", expires_at: DateTime.add(now, 1, :day), updated_at: now]
    )

    :ok
  end

  defp invitation_link(invitation) do
    app_url = Application.fetch_env!(:dhc, :app_url)

    app_url
    |> URI.merge("/members/signup/#{invitation.id}")
    |> Map.put(
      :query,
      URI.encode_query(%{
        "dateOfBirth" => Repository.date_string(invitation.date_of_birth),
        "email" => invitation.email
      })
    )
    |> URI.to_string()
  end

  # ── List helpers ─────────────────────────────────────────────────────

  defp parse_list_options(params) do
    limit = parse_integer(Map.get(params, "limit", "10"))
    sort = Map.get(params, "sort", "createdAt")
    direction = Map.get(params, "direction", "desc")
    q = blank_to_nil(Map.get(params, "q"))

    cond do
      limit not in @allowed_limits ->
        {:error, :invalid_limit}

      sort not in @allowed_sort_fields ->
        {:error, :invalid_sort}

      direction not in @allowed_directions ->
        {:error, :invalid_direction}

      true ->
        {:ok,
         %{
           limit: limit,
           sort: sort,
           direction: direction,
           q: q,
           cursor: blank_to_nil(Map.get(params, "cursor"))
         }}
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp list_cursor_context(opts) do
    %{"limit" => opts.limit, "sort" => opts.sort, "direction" => opts.direction, "q" => opts.q}
  end

  defp list_total_count(opts) do
    opts
    |> base_list_query()
    |> select([i], count(i.id))
    |> Repo.one()
  end

  defp list_rows(opts, cursor) do
    query_direction = CursorPagination.query_direction(opts, cursor)

    opts
    |> base_list_query()
    |> CursorPagination.apply_cursor(cursor, opts, @list_sort_specs)
    |> CursorPagination.apply_order(list_order_field(opts.sort), query_direction)
    |> limit(^opts.limit + 1)
    |> Repo.all()
    |> CursorPagination.maybe_reverse(cursor)
  end

  defp base_list_query(opts) do
    base_query =
      from i in Invitation,
        where: i.status in ^@visible_statuses

    base_query
    |> filter_list_search(opts.q)
  end

  # `search_text` is a generated tsvector column on `invitations`; websearch
  # over it replaces the prior client-side `textSearch("search_text", ...)`.
  defp filter_list_search(query, nil), do: query

  defp filter_list_search(query, q) do
    where(
      query,
      [i],
      fragment("? @@ websearch_to_tsquery('english', ?)", field(i, :search_text), ^q)
    )
  end

  defp list_order_field("email"), do: :email
  defp list_order_field("status"), do: :status
  defp list_order_field("expiresAt"), do: :expires_at
  defp list_order_field("createdAt"), do: :created_at

  defp list_cursor_value(row, opts) do
    spec = Map.fetch!(@list_sort_specs, opts.sort)
    value = Map.fetch!(row, spec.field)

    if encode = Map.get(spec, :encode), do: encode.(value), else: value
  end
end
