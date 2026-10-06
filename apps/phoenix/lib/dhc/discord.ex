defmodule Dhc.Discord do
  @moduledoc """
  Discord server operations owned by the application.

  Callers use this context instead of depending on a Discord client library.
  """

  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Auth.UserRole
  alias Dhc.Discord.{ApiError, GuildMemberCache, JoinGrant}
  alias Dhc.Invitations.Invitation
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  import Ecto.Changeset, only: [change: 2, unique_constraint: 3]
  import Ecto.Query

  @join_grant_salt "discord join grant:v1"
  @doctor_cache_ttl_seconds 60

  @spec list_guild_members() :: Dhc.Discord.Adapter.list_members_result()
  def list_guild_members do
    adapter().list_guild_members(guild_id())
  end

  @spec add_guild_member(String.t(), String.t(), String.t()) ::
          Dhc.Discord.Adapter.add_member_result()
  def add_guild_member(user_id, access_token, nickname) do
    adapter().add_guild_member(guild_id(), user_id, access_token, nickname)
  end

  @spec kick_guild_member(String.t(), String.t()) :: Dhc.Discord.Adapter.kick_member_result()
  def kick_guild_member(user_id, reason) do
    adapter().kick_guild_member(guild_id(), user_id, reason)
  end

  @typedoc """
  Why a Discord announcement call failed (ALE-309 table, ALE-348 seam):
  `:rate_limited` (429 / retry-after), `:connection_refused` (refused before
  submission), `:permission` (403), `:unknown_channel` (404),
  `:payload_rejected` (400), `:timeout` (408 / transport timeout),
  `:server_error` (5xx), and `:ambiguous` for every other failure,
  including a success without a trustworthy id. How a caller treats each
  cause is the caller's policy.
  """
  @type failure ::
          :rate_limited
          | :connection_refused
          | :permission
          | :unknown_channel
          | :payload_rejected
          | :timeout
          | :server_error
          | :ambiguous

  @typedoc "A classified failure with a `code: message` detail for evidence."
  @type classified_error :: {:error, {failure(), String.t()}}

  @doc """
  Posts a channel message through the configured Discord adapter.

  `params` carries `%{content:, allowed_mentions:, nonce:}`. `allowed_mentions`
  is forwarded verbatim — this seam never adds mentions itself; the caller
  owns mention policy (ALE-309). Returns the Discord message id, or a
  classified `t:failure/0` with its detail; callers never see transport or
  `Dhc.Discord.ApiError` shapes.
  """
  @spec create_message(String.t(), map()) ::
          {:ok, %{message_id: String.t()}} | classified_error()
  def create_message(channel_id, params) when is_map(params) do
    adapter().create_message(channel_id, params)
    |> normalize_id(:message_id, "invalid Discord message response")
  end

  @doc """
  Opens a thread on an existing channel message (ALE-320).

  `params` carries `%{name:, auto_archive_duration:}`. Thread failures never
  repost the message — the caller keeps the standing message id and records
  the classified outcome.
  """
  @spec create_thread_from_message(String.t(), String.t(), map()) ::
          {:ok, %{thread_id: String.t()}} | classified_error()
  def create_thread_from_message(channel_id, message_id, params) when is_map(params) do
    adapter().create_thread_from_message(channel_id, message_id, params)
    |> normalize_id(:thread_id, "invalid Discord thread response")
  end

  defp normalize_id({:ok, result}, key, invalid_message) when is_map(result) do
    case Map.fetch(result, key) do
      {:ok, id} when is_binary(id) and id != "" ->
        {:ok, Map.new([{key, id}])}

      {:ok, id} when is_integer(id) ->
        {:ok, Map.new([{key, Integer.to_string(id)}])}

      _unexpected ->
        uncertain(invalid_message)
    end
  end

  defp normalize_id({:ok, _unexpected}, _key, invalid_message) do
    uncertain(invalid_message)
  end

  defp normalize_id({:error, reason}, _key, _invalid_message) do
    classify_wrapped(reason)
  end

  defp uncertain(message) do
    {:error, {:ambiguous, detail(%ApiError{status: 502, message: message})}}
  end

  defp classify_wrapped(reason) do
    error = to_api_error(reason)
    {:error, {classify_error(error), detail(error)}}
  end

  defp to_api_error(%ApiError{} = error), do: error

  defp to_api_error(%{status: status} = error) when is_integer(status) do
    %ApiError{
      status: status,
      code: Map.get(error, :code),
      message: Map.get(error, :message),
      details: Map.get(error, :details, error)
    }
  end

  defp to_api_error(reason) do
    %ApiError{status: 0, message: "Discord request failed", details: reason}
  end

  defp detail(%ApiError{code: code, message: message}), do: "#{code}: #{message}"

  # Failure classification (ALE-309 table, ALE-320 seam, ALE-348 causes).
  # Unknown errors default to :ambiguous — never retry without positive
  # proof the message was not accepted.
  defp classify_error(%ApiError{status: 429}), do: :rate_limited
  defp classify_error(%ApiError{details: {:retry_after, _millis}}), do: :rate_limited
  defp classify_error(%ApiError{details: %{retry_after: _}}), do: :rate_limited

  defp classify_error(%ApiError{status: status} = error)
       when status == 0 or status == 408 do
    cond do
      connection_refused?(error.details) -> :connection_refused
      status == 408 or error.details == :timeout -> :timeout
      true -> :ambiguous
    end
  end

  defp classify_error(%ApiError{status: 403}), do: :permission
  defp classify_error(%ApiError{status: 404}), do: :unknown_channel
  defp classify_error(%ApiError{status: 400}), do: :payload_rejected
  defp classify_error(%ApiError{status: status}) when status >= 500, do: :server_error
  defp classify_error(%ApiError{}), do: :ambiguous

  defp connection_refused?(:econnrefused), do: true
  defp connection_refused?({:connection_died, reason}), do: connection_refused?(reason)
  defp connection_refused?({:econnrefused, _detail}), do: true
  defp connection_refused?(%{reason: reason}), do: connection_refused?(reason)

  defp connection_refused?(reason) when is_tuple(reason) do
    reason |> Tuple.to_list() |> Enum.any?(&connection_refused?/1)
  end

  defp connection_refused?(_reason), do: false

  @spec doctor_report(keyword()) :: {:ok, map()} | {:error, term()}
  def doctor_report(options \\ []) do
    refresh? = Keyword.get(options, :refresh, false)

    with {:ok, guild_members, fetched_at} <-
           GuildMemberCache.fetch(
             guild_id(),
             refresh?,
             &list_guild_members/0,
             @doctor_cache_ttl_seconds
           ) do
      {:ok, build_doctor_report(guild_members, fetched_at)}
    end
  end

  @spec doctor_kick([String.t()], Ecto.UUID.t(), String.t() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def doctor_kick(user_ids, admin_principal_id, note) do
    with {:ok, guild_members} <- list_guild_members(),
         {:ok, admin_name} <- doctor_admin_name(admin_principal_id) do
      members = doctor_members()
      members_by_principal = Map.new(members, &{&1.principal_id, &1})
      guild_members_by_id = Map.new(guild_members, &{&1.user_id, &1})

      kick_context = %{
        identities: Map.new(active_discord_identities(), &{&1.provider_subject, &1}),
        assignments: Map.new(active_staged_assignments(), &{&1.provider_subject, &1}),
        members: members_by_principal,
        roles: roles_by_principal(),
        admin_name: admin_name,
        note: note,
        multiple_targets?: match?([_, _ | _], user_ids)
      }

      results =
        Enum.map(user_ids, fn user_id ->
          guild_member = Map.get(guild_members_by_id, user_id)
          kick_doctor_target(user_id, guild_member, kick_context)
        end)

      {:ok, results}
    end
  end

  defp doctor_admin_name(principal_id) do
    query =
      from(profile in UserProfile,
        where: profile.principal_id == ^principal_id,
        select: {profile.first_name, profile.last_name}
      )

    case Repo.one(query) do
      {first_name, last_name} -> {:ok, "#{first_name} #{last_name}"}
      nil -> {:error, :admin_not_found}
    end
  end

  defp kick_doctor_target(user_id, nil, _context) do
    kick_result(user_id, :already_left)
  end

  defp kick_doctor_target(user_id, guild_member, context) do
    row =
      classify_guild_member(
        guild_member,
        context.identities,
        context.assignments,
        context.members,
        context.roles
      )

    cond do
      guild_member.bot ->
        kick_result(user_id, :refused, reason: "bot account")

      row.protected ->
        kick_result(user_id, :refused, reason: "protected member")

      row.membership_status == :paused ->
        kick_result(user_id, :refused, reason: "paused member")

      row.bucket == :linked_active ->
        kick_result(user_id, :refused, reason: "active linked member")

      row.bucket == :pending_link and context.multiple_targets? ->
        kick_result(user_id, :refused, reason: "pending links can only be kicked one at a time")

      row.bucket in [:linked_inactive, :pending_link, :unrecognized] ->
        execute_doctor_kick(user_id, row.bucket, context.admin_name, context.note)
    end
  end

  defp execute_doctor_kick(user_id, bucket, admin_name, note) do
    reason = doctor_audit_reason(admin_name, bucket, note)

    case kick_guild_member(user_id, reason) do
      :ok ->
        kick_result(user_id, :kicked)

      {:error, %ApiError{status: 404}} ->
        kick_result(user_id, :already_left)

      {:error, %ApiError{message: message}} when is_binary(message) and message != "" ->
        kick_result(user_id, :failed, error: message)

      {:error, _error} ->
        kick_result(user_id, :failed, error: "Discord request failed")
    end
  end

  defp doctor_audit_reason(admin_name, bucket, note) do
    base = "DHC Doctor — #{admin_name}: #{bucket}"

    case note do
      note when is_binary(note) ->
        case String.trim(note) do
          "" -> base
          trimmed -> "#{base} — #{trimmed}"
        end

      _other ->
        base
    end
  end

  defp kick_result(user_id, outcome, options \\ []) do
    %{
      discord_user_id: user_id,
      outcome: outcome,
      reason: Keyword.get(options, :reason),
      error: Keyword.get(options, :error)
    }
  end

  defp build_doctor_report(guild_members, fetched_at) do
    humans = Enum.reject(guild_members, & &1.bot)
    members = doctor_members()
    members_by_principal = Map.new(members, &{&1.principal_id, &1})
    identities = active_discord_identities()
    assignments = active_staged_assignments()
    roles = roles_by_principal()

    identities_by_subject = Map.new(identities, &{&1.provider_subject, &1})
    identities_by_principal = Map.new(identities, &{&1.principal_id, &1})
    assignments_by_subject = Map.new(assignments, &{&1.provider_subject, &1})
    assignments_by_principal = Map.new(assignments, &{&1.principal_id, &1})

    rows =
      Enum.map(humans, fn guild_member ->
        classify_guild_member(
          guild_member,
          identities_by_subject,
          assignments_by_subject,
          members_by_principal,
          roles
        )
      end)

    grouped = Enum.group_by(rows, & &1.bucket, &Map.delete(&1, :bucket))
    guild_user_ids = MapSet.new(humans, & &1.user_id)
    pending_grants = pending_join_grant_principals()

    missing_members =
      members
      |> Enum.flat_map(fn member ->
        missing_member(
          member,
          identities_by_principal,
          assignments_by_principal,
          guild_user_ids,
          pending_grants
        )
      end)
      |> Enum.sort_by(&{&1.member.last_name, &1.member.first_name, &1.member.id})

    %{
      server_members: %{
        linked_active: sorted_bucket(grouped, :linked_active),
        linked_inactive: sorted_bucket(grouped, :linked_inactive),
        pending_link: sorted_bucket(grouped, :pending_link),
        unrecognized: sorted_bucket(grouped, :unrecognized)
      },
      missing_members: missing_members,
      cache: %{fetched_at: fetched_at, ttl_seconds: @doctor_cache_ttl_seconds}
    }
  end

  defp doctor_members do
    from(member in MemberProfile,
      join: profile in UserProfile,
      on: profile.id == member.user_profile_id and member.id == profile.principal_id,
      select: %{
        principal_id: profile.principal_id,
        first_name: profile.first_name,
        last_name: profile.last_name,
        is_active: profile.is_active,
        subscription_paused_until: member.subscription_paused_until
      }
    )
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :membership_status, membership_status(&1)))
  end

  defp active_discord_identities do
    Repo.all(
      from(identity in ExternalIdentity,
        where: identity.provider == "discord" and is_nil(identity.retired_at),
        select: %{
          principal_id: identity.principal_id,
          provider_subject: identity.provider_subject,
          metadata: identity.metadata
        }
      )
    )
  end

  defp active_staged_assignments do
    Repo.all(
      from(assignment in Dhc.Discord.StagedAssignment,
        where: assignment.provider == "discord" and assignment.state in ["proposed", "approved"],
        select: %{
          principal_id: assignment.principal_id,
          provider_subject: assignment.provider_subject,
          username_snapshot: assignment.username_snapshot
        }
      )
    )
  end

  defp roles_by_principal do
    UserRole
    |> Repo.all()
    |> Enum.group_by(& &1.principal_id, & &1.role)
  end

  defp pending_join_grant_principals do
    now = DateTime.utc_now()

    join_grant_invitation()
    |> where([grant], not is_nil(grant.encrypted_access_token) and grant.expires_at > ^now)
    |> select([_grant, _attempt, invitation], invitation.prospective_principal_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp classify_guild_member(
         guild_member,
         identities_by_subject,
         assignments_by_subject,
         members_by_principal,
         roles
       ) do
    case Map.get(identities_by_subject, guild_member.user_id) do
      %{principal_id: principal_id} ->
        linked_row(guild_member, Map.get(members_by_principal, principal_id), roles)

      nil ->
        pending_or_unrecognized_row(
          guild_member,
          Map.get(assignments_by_subject, guild_member.user_id),
          members_by_principal,
          roles
        )
    end
  end

  defp linked_row(guild_member, nil, _roles), do: unrecognized_row(guild_member)

  defp linked_row(guild_member, member, roles) do
    bucket = if member.is_active, do: :linked_active, else: :linked_inactive
    protected = protected?(member.principal_id, roles)

    guild_row(guild_member, member, protected,
      bucket: bucket,
      kickable: bucket == :linked_inactive and not protected
    )
  end

  defp pending_or_unrecognized_row(guild_member, nil, _members, _roles),
    do: unrecognized_row(guild_member)

  defp pending_or_unrecognized_row(guild_member, assignment, members, roles) do
    case Map.get(members, assignment.principal_id) do
      nil ->
        unrecognized_row(guild_member)

      member ->
        protected = protected?(member.principal_id, roles)

        guild_row(guild_member, member, protected,
          bucket: :pending_link,
          kickable: not protected
        )
    end
  end

  defp unrecognized_row(guild_member) do
    guild_row(guild_member, nil, false, bucket: :unrecognized, kickable: true)
  end

  defp guild_row(guild_member, member, protected, options) do
    %{
      bucket: Keyword.fetch!(options, :bucket),
      discord_user_id: guild_member.user_id,
      username: guild_member.username,
      display_name: guild_member.display_name,
      avatar: guild_member.avatar,
      joined_at: guild_member.joined_at,
      member: member_summary(member),
      membership_status: member && member.membership_status,
      protected: protected,
      kickable: Keyword.fetch!(options, :kickable)
    }
  end

  defp missing_member(
         member,
         identities_by_principal,
         assignments_by_principal,
         guild_user_ids,
         pending_grants
       ) do
    {link_status, discord_user_id, discord_username} =
      cond do
        identity = Map.get(identities_by_principal, member.principal_id) ->
          {:linked, identity.provider_subject, discord_username_from_metadata(identity.metadata)}

        assignment = Map.get(assignments_by_principal, member.principal_id) ->
          {:pending, assignment.provider_subject, assignment.username_snapshot}

        true ->
          {:never_linked, nil, nil}
      end

    if discord_user_id && MapSet.member?(guild_user_ids, discord_user_id) do
      []
    else
      [
        %{
          member: member_summary(member),
          membership_status: member.membership_status,
          link_status: link_status,
          discord_user_id: discord_user_id,
          discord_username: discord_username,
          auto_join_pending: MapSet.member?(pending_grants, member.principal_id)
        }
      ]
    end
  end

  defp discord_username_from_metadata(%{"username" => username})
       when is_binary(username) and username != "",
       do: username

  defp discord_username_from_metadata(%{"preferred_username" => username})
       when is_binary(username) and username != "",
       do: username

  defp discord_username_from_metadata(_metadata), do: nil

  defp member_summary(nil), do: nil

  defp member_summary(member) do
    %{id: member.principal_id, first_name: member.first_name, last_name: member.last_name}
  end

  defp protected?(principal_id, roles) do
    roles
    |> Map.get(principal_id, [])
    |> Enum.any?(&(&1 != "member"))
  end

  defp membership_status(%{is_active: false}), do: :inactive

  defp membership_status(%{subscription_paused_until: paused_until})
       when not is_nil(paused_until) do
    if DateTime.after?(paused_until, DateTime.utc_now()), do: :paused, else: :active
  end

  defp membership_status(_member), do: :active

  defp sorted_bucket(grouped, bucket) do
    grouped
    |> Map.get(bucket, [])
    |> Enum.sort_by(&{&1.display_name, &1.discord_user_id})
  end

  @spec create_join_grant(Ecto.UUID.t(), map()) ::
          {:ok, JoinGrant.t()} | {:error, :invalid_token | Ecto.Changeset.t()}
  def create_join_grant(continuation_id, token) when is_map(token) do
    with %{"access_token" => access_token, "expires_in" => expires_in}
         when is_binary(access_token) and access_token != "" and is_integer(expires_in) and
                expires_in > 0 <- token,
         %InvitationAcceptanceDiscordContinuation{} = continuation <-
           Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %JoinGrant{}
      |> change(%{
        continuation_id: continuation.id,
        attempt_id: continuation.attempt_id,
        encrypted_access_token: encrypt_access_token(access_token),
        expires_at: DateTime.add(now, expires_in, :second)
      })
      |> unique_constraint(:continuation_id,
        name: :discord_join_grants_continuation_id_index
      )
      |> Repo.insert()
    else
      _invalid -> {:error, :invalid_token}
    end
  end

  def create_join_grant(_continuation_id, _token), do: {:error, :invalid_token}

  @spec join_grant_access_token(JoinGrant.t()) ::
          {:ok, String.t()} | {:error, :unavailable | :invalid}
  def join_grant_access_token(%JoinGrant{encrypted_access_token: nil}),
    do: {:error, :unavailable}

  def join_grant_access_token(%JoinGrant{encrypted_access_token: encrypted_access_token}) do
    case Plug.Crypto.decrypt(secret_key_base(), @join_grant_salt, encrypted_access_token) do
      {:ok, access_token} when is_binary(access_token) -> {:ok, access_token}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  @spec zeroize_join_grant(JoinGrant.t()) :: {:ok, JoinGrant.t()} | {:error, Ecto.Changeset.t()}
  def zeroize_join_grant(%JoinGrant{} = grant) do
    grant
    |> change(encrypted_access_token: nil)
    |> Repo.update()
  end

  @spec cleanup_expired_join_grants() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired_join_grants do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expired = from(grant in JoinGrant, where: grant.expires_at <= ^now)

    Repo.transaction(fn ->
      Repo.update_all(expired, set: [encrypted_access_token: nil, updated_at: now])
      {deleted_count, _grants} = Repo.delete_all(expired)
      deleted_count
    end)
  end

  @spec prepare_guild_join(Ecto.UUID.t()) ::
          {:ok,
           %{
             grant: JoinGrant.t(),
             user_id: String.t(),
             access_token: String.t(),
             nickname: String.t()
           }}
          | {:terminal, atom()}
          | {:error, atom()}
  def prepare_guild_join(grant_id) do
    case Repo.get(JoinGrant, grant_id) do
      nil ->
        {:terminal, :grant_not_found}

      grant ->
        prepare_existing_guild_join(grant)
    end
  end

  @doc """
  Returns the member-facing identity behind a guild-join grant.

  The join worker needs this on failure paths: a denied (401/403) or
  retries-exhausted join must notify the affected principal, but
  `prepare_guild_join/1` only returns the Discord credentials on success.
  Returns only identifiers — never tokens, subjects, or contact details.
  """
  @spec guild_join_context(Ecto.UUID.t()) ::
          {:ok,
           %{principal_id: Ecto.UUID.t(), attempt_id: Ecto.UUID.t(), invitation_id: Ecto.UUID.t()}}
          | {:error, :not_found}
  def guild_join_context(grant_id) do
    query =
      join_grant_invitation()
      |> where([grant], grant.id == ^grant_id)
      |> select([grant, _attempt, invitation], %{
        principal_id: invitation.prospective_principal_id,
        attempt_id: grant.attempt_id,
        invitation_id: invitation.id
      })

    case Repo.one(query) do
      nil -> {:error, :not_found}
      context -> {:ok, context}
    end
  end

  # Joins a join grant to the acceptance attempt it belongs to and the
  # Invitation that attempt was opened for. Read-only: nothing here writes or
  # transitions an acceptance row, so it is not a subject for `Acceptance.Locked`
  # (the same reasoning as `pending_join_grant_principals/0`).
  defp join_grant_invitation do
    from(grant in JoinGrant,
      join: attempt in InvitationAcceptanceAttempt,
      on: attempt.id == grant.attempt_id,
      join: invitation in Invitation,
      on: invitation.id == attempt.invitation_id
    )
  end

  defp prepare_existing_guild_join(grant) do
    if DateTime.compare(grant.expires_at, DateTime.utc_now()) == :gt do
      with {:ok, access_token} <- join_grant_access_token(grant),
           {:ok, member} <- discord_member_for_grant(grant) do
        {:ok,
         %{
           grant: grant,
           user_id: member.user_id,
           access_token: access_token,
           nickname: member.first_name
         }}
      else
        {:error, :unavailable} -> {:terminal, :grant_unavailable}
        {:error, :invalid} -> terminalize_grant(grant, :invalid_grant)
        {:error, reason} -> {:error, reason}
      end
    else
      terminalize_grant(grant, :grant_expired)
    end
  end

  defp discord_member_for_grant(grant) do
    query =
      from(identity in ExternalIdentity,
        join: attempt in InvitationAcceptanceAttempt,
        on: attempt.id == ^grant.attempt_id,
        join: invitation in Invitation,
        on: invitation.id == attempt.invitation_id,
        where:
          identity.principal_id == invitation.prospective_principal_id and
            identity.provider == "discord" and is_nil(identity.retired_at),
        select: %{user_id: identity.provider_subject, first_name: invitation.first_name}
      )

    case Repo.one(query) do
      %{user_id: user_id, first_name: first_name} = member
      when is_binary(user_id) and is_binary(first_name) ->
        {:ok, member}

      nil ->
        {:error, :discord_identity_not_found}
    end
  end

  defp terminalize_grant(grant, reason) do
    case zeroize_join_grant(grant) do
      {:ok, _grant} -> {:terminal, reason}
      {:error, _changeset} -> {:error, :grant_zeroization_failed}
    end
  end

  defp encrypt_access_token(access_token) do
    Plug.Crypto.encrypt(secret_key_base(), @join_grant_salt, access_token)
  end

  defp secret_key_base, do: DhcWeb.Endpoint.config(:secret_key_base)

  defp adapter, do: Application.fetch_env!(:dhc, :discord_adapter)
  defp guild_id, do: Application.fetch_env!(:dhc, :discord_guild_id)
end
