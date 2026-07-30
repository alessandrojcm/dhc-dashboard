defmodule Dhc.Invitations do
  @moduledoc """
  Invitation context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Email.Worker, as: EmailWorker
  alias Dhc.Auth.UserRole
  alias Dhc.CursorPagination
  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.Pricing
  alias Dhc.Invitations.Repository
  alias Dhc.MemberProfiles.MemberProfile
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
  Returns public signup pricing for a pending Invitation.
  """
  @spec pricing(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def pricing(invitation_id, coupon_code \\ nil) when is_binary(invitation_id) do
    Pricing.pricing_for_invitation(invitation_id, coupon_code)
  end

  @doc """
  Verifies public Invitation credentials and returns a short-lived signed token.
  """
  @spec verify_credentials(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_credentials}
  def verify_credentials(invitation_id, email, date_of_birth) do
    with {:ok, date} <- parse_date(date_of_birth),
         true <- credentials_match?(invitation_id, email, date),
         {:ok, token} <- issue_verification_token(invitation_id, email, date) do
      {:ok, token}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  @doc """
  Issues the opaque signed token used by the public accept endpoint.
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

  @doc """
  Converts a verified Invitation into a Member in one database transaction.

  ALE-162 (ADR 0010): acceptance is the atomic point at which a prospective
  member becomes a Principal and a Member. In one `Repo.transaction` it:

    * locks the pending invitation `FOR UPDATE`;
    * creates a Stripe customer (or reuses `invitation.stripe_customer_id`
      if the pricing endpoint already attached one);
    * completes the Stripe payment (SetupIntent + subscriptions + first
      invoice confirmation) — failure rolls back the whole transaction;
    * creates the `Principal` with `id = invitation.user_id` and the
      invitation's email as the authoritative normalized login email;
    * reuses the existing waitlist `UserProfile` when the invitation came
      from a waitlist entry, or creates a fresh one (ALE-176) — in both
      cases the UserProfile ends keyed by `principal_id = invitation
      .user_id` (the post-M1 invariant holds from birth);
    * creates the `MemberProfile` keyed by `invitation.user_id`;
    * grants the `member` role;
    * flips the invitation to `accepted`;
    * sets `user_profile.is_active = true`;
    * marks any waitlist entry for the invitation email `joined`.

  It does **not** establish a Session or send a magic link — acceptance is
  registration, not login. The first sign-in is a normal magic-link (or
  Discord) login through `Dhc.Auth`.

  ## Replay and failure semantics

  The invitation-status flip is the replay defense: a second `accept` call
  finds no pending invitation and rolls back with `:invalid_invitation`. The
  15-minute verification token is **not** single-use (ADR 0010). A pre-existing
  `MemberProfile` for `invitation.user_id` is treated as `:invalid_invitation`
  and rolls back. Any failure — Stripe, Principal insert, UserProfile insert,
  MemberProfile insert — rolls back the entire record set, leaving no partial
  account (the spec's "no partial record set" invariant).
  """
  @spec accept(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, %{member_id: String.t()}} | {:error, term()}
  def accept(
        invitation_id,
        verification_token,
        next_of_kin_name,
        next_of_kin_phone,
        payment_attrs
      ) do
    with {:ok, claims} <- verify_token(verification_token),
         :ok <- token_matches_invitation(claims, invitation_id) do
      Repo.transaction(fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        invitation =
          from(i in Invitation,
            where:
              i.id == ^invitation_id and i.status == "pending" and
                i.expires_at > ^now,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if is_nil(invitation) do
          Repo.rollback(:invalid_invitation)
        end

        # Replay defense: a pre-existing MemberProfile for this user_id means
        # a prior acceptance already committed. The invitation-status flip is
        # the primary replay guard; this is a belt-and-braces check.
        if Repo.exists?(from(m in MemberProfile, where: m.id == ^invitation.user_id)) do
          Repo.rollback(:invalid_invitation)
        end

        # Resolve the Stripe customer. The pricing endpoint may have already
        # attached one to the invitation; otherwise acceptance creates one
        # here. The customer id is needed by StripePayment.complete/1.
        customer_id =
          case invitation.stripe_customer_id do
            nil -> create_acceptance_customer!(invitation)
            "" -> create_acceptance_customer!(invitation)
            existing -> existing
          end

        payment_attrs =
          payment_attrs
          |> Map.put(:customer_id, customer_id)
          |> Map.put(:invitation_id, invitation.id)

        case payment_processor().complete(payment_attrs) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback({:payment_failed, reason})
        end

        # ALE-162: create the Principal with id = invitation.user_id. This is
        # the post-M1 invariant from birth: principals.id == user_profiles
        # .supabase_user_id == member_profiles.id. The Principal's email is
        # the authoritative normalized login email from the invitation.
        case Auth.register_principal_with_id(invitation.user_id, %{email: invitation.email}) do
          {:ok, _principal} -> :ok
          {:error, _changeset} -> Repo.rollback(:principal_creation_failed)
        end

        # ALE-176: reuse the existing waitlist UserProfile instead of creating
        # a duplicate. `Dhc.Waitlist.create_entry/1` creates an inactive
        # `user_profiles` row carrying the intake-captured fields (first/last/
        # DOB/gender/pronouns/phone/social_media_consent/medical_conditions)
        # plus an optional guardian, keyed by `waitlist_id`. When the
        # invitation came from a waitlist entry, lock that row `FOR UPDATE`
        # and flip it to the member state — preserving the intake fields and
        # guardian linkage. When there is no waitlist profile (direct invite
        # with no waitlist_id, or the profile was never created), acceptance
        # materializes a fresh UserProfile from the invitation row, matching
        # the pre-ALE-176 behavior.
        user_profile_id =
          reuse_or_create_user_profile(invitation, customer_id, now)

        member_profile = %MemberProfile{
          id: invitation.user_id,
          user_profile_id: user_profile_id,
          next_of_kin_name: next_of_kin_name,
          next_of_kin_phone: next_of_kin_phone,
          preferred_weapon: [],
          membership_start_date: now,
          insurance_form_submitted: true,
          additional_data: %{}
        }

        case Repo.insert(member_profile) do
          {:ok, _member_profile} -> :ok
          {:error, _changeset} -> Repo.rollback(:invalid_invitation)
        end

        invitation
        |> Ecto.Changeset.change(status: "accepted")
        |> Repo.update!()

        Repo.insert_all(
          UserRole,
          [[principal_id: invitation.user_id, role: "member"]],
          on_conflict: :nothing,
          conflict_target: [:principal_id, :role]
        )

        from(w in WaitlistEntry, where: w.email == ^invitation.email)
        |> Repo.update_all(
          set: [
            status: "joined",
            last_status_change: now
          ]
        )

        %{member_id: invitation.user_id}
      end)
    end
  end

  defp create_acceptance_customer!(%Invitation{} = invitation) do
    name =
      [invitation.first_name, invitation.last_name]
      |> Enum.filter(&(&1 not in [nil, ""]))
      |> Enum.join(" ")

    case payment_processor().create_customer(
           invitation.email,
           name,
           invitation.created_by || invitation.user_id,
           invitation.id
         ) do
      {:ok, customer_id} -> customer_id
      {:error, reason} -> Repo.rollback({:payment_failed, reason})
    end
  end

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
        principal_id: invitation.user_id,
        is_active: true,
        customer_id: customer_id,
        updated_at: now
      )
      |> Repo.update!()

      waitlist_profile.id
    else
      user_profile = %UserProfile{
        id: Ecto.UUID.generate(),
        principal_id: invitation.user_id,
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
  """
  @spec resend_invitation_emails([String.t()]) ::
          {:ok, %{succeeded: non_neg_integer(), failed: non_neg_integer()}}
  def resend_invitation_emails(emails) when is_list(emails) and length(emails) > 0 do
    invite_data = list_invitation_resend_data(emails)

    succeeded =
      invite_data
      |> Enum.map(&enqueue_invitation_email/1)
      |> Enum.count(&match?(:ok, &1))

    found_emails = Enum.map(invite_data, & &1.email)

    if found_emails != [] do
      expire_for_resend(found_emails)
    end

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
        where: i.id == ^invitation_id,
        where: fragment("lower(?)", i.email) == ^normalized_email,
        where: i.status == "pending",
        where: i.expires_at > ^now,
        where: i.date_of_birth == ^date_of_birth,
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

  defp payment_processor do
    Application.get_env(:dhc, :invitation_payment_processor, Dhc.Invitations.StripePayment)
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
    from(i in Invitation,
      where: i.email in ^emails,
      select: %{
        id: i.id,
        email: i.email,
        first_name: i.first_name,
        last_name: i.last_name,
        date_of_birth: i.date_of_birth
      }
    )
    |> Repo.all()
  end

  defp enqueue_invitation_email(invitation) do
    args = %{
      "email" => invitation.email,
      "transactional_id" => @invite_email_template,
      "data_variables" => %{
        "firstName" => invitation.first_name || "",
        "lastName" => invitation.last_name || "",
        "invitationLink" => invitation_link(invitation)
      }
    }

    case Oban.insert(EmailWorker.new(args)) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp expire_for_resend(emails) do
    from(i in Invitation, where: i.email in ^emails)
    |> Repo.update_all(
      set: [status: "pending", expires_at: DateTime.add(DateTime.utc_now(), 1, :day)]
    )
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
