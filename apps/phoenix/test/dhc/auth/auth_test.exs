defmodule Dhc.AuthTest do
  use Dhc.DataCase, async: true

  alias Dhc.Auth
  alias Dhc.Auth.Principal
  alias Dhc.Auth.PrincipalToken
  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Discord.{StagedAssignment, StagedAssignmentAuditEvent}
  alias Dhc.Repo

  import Dhc.AuthFixtures

  describe "get_principal_by_email/1" do
    test "returns nil for an unknown email" do
      refute Auth.get_principal_by_email("nobody@example.com")
    end

    test "returns the Principal for a matching email" do
      principal = principal_fixture()
      found = Auth.get_principal_by_email(principal.email)
      assert %Principal{} = found
      assert found.id == principal.id
    end

    test "normalizes email before lookup (case-insensitive, trimmed)" do
      principal = principal_fixture(email: "member@example.com")
      found = Auth.get_principal_by_email("  MEMBER@EXAMPLE.COM  ")
      assert %Principal{} = found
      assert found.id == principal.id
    end
  end

  describe "register_principal/1" do
    test "normalizes email on insert" do
      {:ok, principal} = Auth.register_principal(%{email: "  Mixed.Case@Example.com  "})
      assert principal.email == "mixed.case@example.com"
    end

    test "rejects a duplicate normalized email (citext)" do
      principal_fixture(email: "dup@example.com")
      {:error, changeset} = Auth.register_principal(%{email: "DUP@example.com"})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "rejects malformed email" do
      {:error, changeset} = Auth.register_principal(%{email: "no-at-sign"})
      assert "must have the @ sign and no spaces" in errors_on(changeset).email
    end
  end

  describe "deliver_magic_link/2" do
    test "returns {:ok, :sent} for an unknown email (non-enumerating)" do
      initial_oban_count = oban_jobs_count()

      assert {:ok, :sent} =
               Auth.deliver_magic_link("nobody@example.com", &"#{&1}")

      # No token row, no email job enqueued.
      assert Repo.aggregate(PrincipalToken, :count) == 0
      assert oban_jobs_count() == initial_oban_count
    end

    test "writes a magic-link token and enqueues an email for a known Principal" do
      principal = principal_fixture()
      initial_oban_count = oban_jobs_count()

      assert {:ok, :sent} =
               Auth.deliver_magic_link(principal.email, fn token ->
                 "https://app.example.com/auth/magic-link?token=#{token}"
               end)

      # One login token row, one email job.
      assert Repo.aggregate(
               from(t in PrincipalToken, where: t.context == "login"),
               :count
             ) == 1

      assert oban_jobs_count() == initial_oban_count + 1
    end

    test "does not disclose Principal existence by side-channel timing of side effects" do
      # Second call to a known Principal still returns the same tuple shape
      # as an unknown one. (This is a shape assertion, not a timing test.)
      principal = principal_fixture()

      assert {:ok, :sent} =
               Auth.deliver_magic_link(principal.email, &"#{&1}")

      assert {:ok, :sent} =
               Auth.deliver_magic_link("unknown@example.com", &"#{&1}")
    end
  end

  describe "consume_magic_link/1" do
    test "consumes a valid token, confirms the Principal, and mints a session" do
      principal = active_principal_fixture(confirmed_at: nil)
      {encoded, _row} = magic_link_token(principal)

      assert {:ok,
              %{
                principal: returned_principal,
                session_token: session_token,
                session: %{is_active: true}
              }} =
               Auth.consume_magic_link(encoded)

      assert returned_principal.id == principal.id
      # confirmed_at was stamped on first consumption.
      assert Auth.get_principal!(principal.id).confirmed_at

      # The session token is verifiable.
      assert {:ok, _} = Auth.get_principal_by_session_token(session_token)
    end

    test "is single-use: the second attempt is invalid" do
      principal = active_principal_fixture()
      {encoded, _row} = magic_link_token(principal)

      assert {:ok, _} = Auth.consume_magic_link(encoded)
      assert {:error, :invalid} = Auth.consume_magic_link(encoded)
    end

    test "deletes outstanding magic-link tokens for the principal on consumption" do
      principal = active_principal_fixture()
      {_, _} = magic_link_token(principal)
      {_, _} = magic_link_token(principal)

      assert Repo.aggregate(
               from(t in PrincipalToken, where: [principal_id: ^principal.id, context: "login"]),
               :count
             ) == 2

      {encoded, _} = magic_link_token(principal)
      assert {:ok, _} = Auth.consume_magic_link(encoded)

      # All login tokens for this principal are gone (including the consumed
      # one and the two outstanding).
      assert Repo.aggregate(
               from(t in PrincipalToken, where: [principal_id: ^principal.id, context: "login"]),
               :count
             ) == 0
    end

    test "consumes and confirms a valid token for an inactive Principal without minting a session" do
      principal = inactive_principal_fixture(confirmed_at: nil)
      {encoded, _row} = magic_link_token(principal)

      assert {:error, :inactive_membership} = Auth.consume_magic_link(encoded)
      assert Auth.get_principal!(principal.id).confirmed_at
      assert {:error, :invalid} = Auth.consume_magic_link(encoded)

      refute Repo.exists?(
               from(t in PrincipalToken,
                 where: [principal_id: ^principal.id, context: "session"]
               )
             )
    end

    test "rejects an expired token (older than 15 minutes)" do
      principal = principal_fixture()
      {encoded, row} = magic_link_token(principal)
      # 16 minutes old — past the 15-min window.
      age_token(row.token, -16, :minute)

      assert {:error, :invalid} = Auth.consume_magic_link(encoded)
    end

    test "rejects a token sent to an email that no longer matches the Principal" do
      principal = principal_fixture(email: "old@example.com")
      {encoded, _row} = magic_link_token(principal)

      # Change the principal's email after the link was issued.
      {:ok, _} =
        principal
        |> Principal.email_changeset(%{email: "new@example.com"})
        |> Repo.update()

      assert {:error, :invalid} = Auth.consume_magic_link(encoded)
    end

    test "rejects garbage input without raising" do
      assert {:error, :invalid} = Auth.consume_magic_link("not-a-real-token")
    end

    test "rejects a token for an unknown principal (no row)" do
      assert {:error, :invalid} =
               Auth.consume_magic_link("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    end
  end

  describe "sessions" do
    test "get_principal_by_session_token/1 rejects an unknown token" do
      assert {:error, :invalid} =
               Auth.get_principal_by_session_token(:crypto.strong_rand_bytes(32))
    end

    test "get_principal_by_session_token/1 rejects an expired session (>30 days)" do
      principal = principal_fixture()
      token = session_token(principal)

      # Age the session row past 30 days. age_token matches the stored column
      # value, which is the SHA-256 digest (not the raw cookie) since ALE-182.
      age_token(:crypto.hash(:sha256, token), -31, :day)

      assert {:error, :invalid} = Auth.get_principal_by_session_token(token)
    end

    test "delete_session_token/1 is idempotent" do
      principal = principal_fixture()
      token = session_token(principal)

      assert :ok = Auth.delete_session_token(token)
      assert :ok = Auth.delete_session_token(token)
      assert {:error, :invalid} = Auth.get_principal_by_session_token(token)
    end

    test "delete_all_principal_sessions/1 removes every session for the principal" do
      principal = principal_fixture()
      t1 = session_token(principal)
      t2 = session_token(principal)

      assert :ok = Auth.delete_all_principal_sessions(principal)
      assert {:error, :invalid} = Auth.get_principal_by_session_token(t1)
      assert {:error, :invalid} = Auth.get_principal_by_session_token(t2)
    end
  end

  describe "apply_member_access/2" do
    test "revoking access deletes every authentication token for the Principal" do
      principal = active_principal_fixture()
      profile = Repo.get_by!(Dhc.UserProfiles.UserProfile, principal_id: principal.id)
      session_token = session_token(principal)
      {:ok, socket_token} = Auth.create_socket_token(principal)
      socket_id = DhcWeb.UserSocket.socket_id(principal.id)
      :ok = DhcWeb.Endpoint.subscribe(socket_id)

      assert :ok = Auth.apply_member_access(profile.id, false)

      assert Repo.get!(Dhc.UserProfiles.UserProfile, profile.id).is_active == false
      assert {:error, :invalid} = Auth.get_principal_by_session_token(session_token)
      assert {:error, :invalid} = Auth.get_principal_by_socket_token(socket_token)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^socket_id,
        event: "disconnect",
        payload: %{}
      }

      assert :ok = Auth.apply_member_access(profile.id, true)
      assert {:error, :invalid} = Auth.get_principal_by_session_token(session_token)
      assert {:error, :invalid} = Auth.get_principal_by_socket_token(socket_token)
    end

    test "revocation refuses a nested transaction so disconnect cannot precede commit" do
      principal = active_principal_fixture()
      profile = Repo.get_by!(Dhc.UserProfiles.UserProfile, principal_id: principal.id)
      socket_id = DhcWeb.UserSocket.socket_id(principal.id)
      :ok = DhcWeb.Endpoint.subscribe(socket_id)

      assert {:ok, {:error, :nested_transaction}} =
               Repo.transaction(fn -> Auth.apply_member_access(profile.id, false) end)

      assert Repo.get!(Dhc.UserProfiles.UserProfile, profile.id).is_active == true
      refute_receive %Phoenix.Socket.Broadcast{topic: ^socket_id, event: "disconnect"}
    end

    test "restoring access does not establish a Session" do
      principal = inactive_principal_fixture()
      profile = Repo.get_by!(Dhc.UserProfiles.UserProfile, principal_id: principal.id)

      assert :ok = Auth.apply_member_access(profile.id, true)

      assert Repo.get!(Dhc.UserProfiles.UserProfile, profile.id).is_active == true

      refute Repo.exists?(
               from(t in PrincipalToken,
                 where: [principal_id: ^principal.id, context: "session"]
               )
             )
    end
  end

  # ALE-182 — session tokens are stored as SHA-256 hashes, not plaintext. The
  # migration backfills existing session rows in place so live cookies keep
  # working. These tests pin the before/after behavior of the hashing change.
  describe "session token hashing (ALE-182)" do
    # Characterization: pins the behavior of `build_session_token/1`. Pre-ALE-182
    # the raw cookie bytes were stored verbatim in the `token` column (plaintext);
    # after ALE-182 the column holds the SHA-256 digest. This test was written
    # first asserting the plaintext shape, went red when the fix landed
    # (confirming the behavior changed), and is now inverted to pin the new
    # shape so the suite stays green.
    test "build_session_token/1 stores the SHA-256 digest, not the raw cookie (characterization)" do
      principal = principal_fixture()
      token = session_token(principal)

      row = Repo.one!(from t in PrincipalToken, where: t.context == "session")
      # The column now holds the digest; the raw cookie is 32 random bytes
      # whose SHA-256 is 32 bytes but never equals the input.
      assert row.token == :crypto.hash(:sha256, token)
      refute row.token == token
    end

    # Desired: after ALE-182, the stored column holds the SHA-256 digest and
    # verify/delete resolve the cookie through the hash.
    test "build_session_token/1 stores only the SHA-256 hash and verify/delete work through the hash (desired)" do
      principal = principal_fixture()
      token = session_token(principal)

      row = Repo.one!(from t in PrincipalToken, where: t.context == "session")
      assert row.token == :crypto.hash(:sha256, token)
      # The raw cookie is not what is stored.
      refute row.token == token

      # Verify and delete operate on the raw cookie (hashing happens inside).
      assert {:ok, returned} = Auth.get_principal_by_session_token(token)
      assert returned.id == principal.id

      assert :ok = Auth.delete_session_token(token)
      assert {:error, :invalid} = Auth.get_principal_by_session_token(token)
    end

    # Backfill regression: simulates a pre-migration session row stored as
    # plaintext, runs the migration's in-place backfill, and asserts the
    # existing cookie still authenticates with zero user disruption.
    test "backfilling existing plaintext session rows keeps existing cookies valid (migration regression)" do
      principal = principal_fixture()

      # Insert a session row the pre-ALE-182 way: raw cookie bytes in the
      # token column (what build_session_token/1 did before the fix).
      raw_cookie = :crypto.strong_rand_bytes(32)

      {:ok, _} =
        %PrincipalToken{
          token: raw_cookie,
          context: "session",
          principal_id: principal.id,
          authenticated_at: principal.authenticated_at || DateTime.utc_now(:second)
        }
        |> Repo.insert()

      # The pre-migration row holds plaintext; the new code hashes the
      # incoming cookie before lookup, so the cookie does NOT authenticate
      # yet. This is the window the backfill closes.
      assert {:error, :invalid} = Auth.get_principal_by_session_token(raw_cookie)

      # Run the ALE-182 backfill in place using pgcrypto's installed schema.
      %{rows: [[pgcrypto_schema]]} =
        Repo.query!("""
        SELECT namespace.nspname
        FROM pg_extension extension
        JOIN pg_namespace namespace ON namespace.oid = extension.extnamespace
        WHERE extension.extname = 'pgcrypto'
        """)

      %{rows: [[quoted_pgcrypto_schema]]} =
        Repo.query!("SELECT quote_ident($1)", [pgcrypto_schema])

      %{num_rows: 1} =
        Repo.query!(
          "UPDATE principal_tokens SET token = #{quoted_pgcrypto_schema}.digest(token, 'sha256') WHERE context = 'session'"
        )

      # The existing cookie now authenticates — verify hashes the incoming
      # cookie before lookup, matching the now-hashed column.
      assert {:ok, returned} = Auth.get_principal_by_session_token(raw_cookie)
      assert returned.id == principal.id

      # And the row now stores the digest, not the plaintext.
      row = Repo.one!(from t in PrincipalToken, where: t.context == "session")
      assert row.token == :crypto.hash(:sha256, raw_cookie)

      # Delete also works through the raw cookie.
      assert :ok = Auth.delete_session_token(raw_cookie)
      assert {:error, :invalid} = Auth.get_principal_by_session_token(raw_cookie)
    end
  end

  describe "sign_in_with_discord/1" do
    test "promotes an approved exact-subject assignment before establishing a session" do
      principal = active_principal_fixture(email: "assigned@example.com")
      subject = "discord-approved-assignment"

      assignment =
        Dhc.DiscordAssignmentFixtures.approved_assignment_fixture(principal.id, subject,
          username_snapshot: "mutable-name"
        )

      other = active_principal_fixture(email: "discord-profile@example.com")

      assert {:ok, %{principal: signed_in, session_token: session_token}} =
               Auth.sign_in_with_discord(%{
                 "sub" => subject,
                 "email" => other.email,
                 "email_verified" => true,
                 "preferred_username" => "different-name",
                 "username" => "another-name",
                 "nickname" => "not-a-selector",
                 "avatar" => "not-a-selector"
               })

      assert signed_in.id == principal.id
      assert {:ok, %{id: principal_id}} = Auth.get_principal_by_session_token(session_token)
      assert principal_id == principal.id

      identity = Repo.get_by!(ExternalIdentity, provider: "discord", provider_subject: subject)
      assert identity.principal_id == principal.id
      assert Repo.get!(StagedAssignment, assignment.id).state == "promoted"

      assert Repo.aggregate(
               from(e in StagedAssignmentAuditEvent,
                 where: e.assignment_id == ^assignment.id and e.action == "promoted"
               ),
               :count
             ) == 1
    end

    test "an inactive Member keeps a promoted identity but receives no session" do
      principal = inactive_principal_fixture(email: "inactive-assigned@example.com")
      subject = "discord-inactive-assignment"

      assignment =
        Dhc.DiscordAssignmentFixtures.approved_assignment_fixture(principal.id, subject)

      assert {:error, :invalid} = Auth.sign_in_with_discord(%{"sub" => subject})

      assert Repo.get_by!(ExternalIdentity, provider: "discord", provider_subject: subject).principal_id ==
               principal.id

      assert Repo.get!(StagedAssignment, assignment.id).state == "promoted"

      refute Repo.exists?(
               from(t in PrincipalToken,
                 where: t.principal_id == ^principal.id and t.context == "session"
               )
             )

      profile = Repo.get_by!(Dhc.UserProfiles.UserProfile, principal_id: principal.id)
      assert :ok = Auth.apply_member_access(profile.id, true)

      refute Repo.exists?(
               from(t in PrincipalToken,
                 where: t.principal_id == ^principal.id and t.context == "session"
               )
             )

      assert {:ok, %{session_token: _}} = Auth.sign_in_with_discord(%{"sub" => subject})
    end

    test "unapproved and malformed subjects have neutral outcomes without mutation" do
      principal = active_principal_fixture(email: "unapproved@example.com")
      subject = "discord-unapproved-assignment"

      assignment =
        Dhc.DiscordAssignmentFixtures.approved_assignment_fixture(principal.id, subject)

      assignment
      |> Ecto.Changeset.change(
        state: "withdrawn",
        terminal_at: DateTime.utc_now(),
        terminal_actor_principal_id: principal.id,
        reason_code: "operator_withdrawal"
      )
      |> Repo.update!()

      for claims <- [
            %{"sub" => subject, "email" => principal.email, "email_verified" => false},
            %{"sub" => "unknown-subject"},
            %{"sub" => ""},
            %{"sub" => nil},
            %{"username" => "reviewed-user", "email" => principal.email}
          ] do
        assert {:error, :invalid} = Auth.sign_in_with_discord(claims)
      end

      assert Repo.get!(StagedAssignment, assignment.id).state == "withdrawn"
      refute Repo.exists?(from(i in ExternalIdentity, where: i.principal_id == ^principal.id))
      refute Repo.exists?(from(t in PrincipalToken, where: t.principal_id == ^principal.id))
    end

    test "a failed promotion rolls back identity, state, and promotion audit" do
      principal = active_principal_fixture(email: "rollback-assigned@example.com")
      subject = "discord-rollback-assignment"

      assignment =
        Dhc.DiscordAssignmentFixtures.approved_assignment_fixture(principal.id, subject)

      function_name = "ale218_fail_promotion_#{System.unique_integer([:positive])}"

      Repo.query!("""
      CREATE FUNCTION #{function_name}() RETURNS trigger AS $$
      BEGIN
        IF NEW.assignment_id = '#{assignment.id}'::uuid AND NEW.action = 'promoted' THEN
          RAISE EXCEPTION 'forced promotion audit failure';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)

      Repo.query!("""
      CREATE TRIGGER #{function_name}
        BEFORE INSERT ON staged_discord_assignment_audit_events
        FOR EACH ROW EXECUTE FUNCTION #{function_name}();
      """)

      assert {:error, :invalid} = Auth.sign_in_with_discord(%{"sub" => subject})
      assert Repo.get!(StagedAssignment, assignment.id).state == "approved"
      refute Repo.get_by(ExternalIdentity, provider: "discord", provider_subject: subject)

      assert Repo.aggregate(
               from(e in StagedAssignmentAuditEvent,
                 where: e.assignment_id == ^assignment.id and e.action == "promoted"
               ),
               :count
             ) == 0

      refute Repo.exists?(from(t in PrincipalToken, where: t.principal_id == ^principal.id))
    end

    test "a linked provider subject signs its active Principal in" do
      principal = active_principal_fixture(email: "linked@example.com")

      Repo.insert_all("external_identities", [
        [
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          principal_id: Ecto.UUID.dump!(principal.id),
          provider: "discord",
          provider_subject: "discord-linked-1",
          metadata: %{"email" => "old-profile@example.com"},
          created_at: DateTime.utc_now(:second),
          updated_at: DateTime.utc_now(:second)
        ]
      ])

      assert {:ok, %{principal: signed_in, session_token: session_token}} =
               Auth.sign_in_with_discord(%{
                 "sub" => "discord-linked-1",
                 "email" => "changed-profile@example.com",
                 "email_verified" => true
               })

      assert signed_in.id == principal.id
      assert {:ok, session_principal} = Auth.get_principal_by_session_token(session_token)
      assert session_principal.id == principal.id
    end

    test "an unlinked subject auto-links to one active Principal by verified email" do
      principal = active_principal_fixture(email: "verified@example.com")

      assert {:ok, %{principal: signed_in}} =
               Auth.sign_in_with_discord(%{
                 "sub" => "discord-new-1",
                 "email" => "VERIFIED@example.com",
                 "email_verified" => true,
                 "preferred_username" => "member-name",
                 "picture" => "https://cdn.discordapp.com/avatar.png"
               })

      assert signed_in.id == principal.id
      assert Auth.get_principal!(principal.id).email == "verified@example.com"

      assert %{
               principal_id: principal_id,
               metadata: %{
                 "email" => "VERIFIED@example.com",
                 "email_verified" => true,
                 "preferred_username" => "member-name",
                 "picture" => "https://cdn.discordapp.com/avatar.png"
               }
             } =
               Repo.get_by!(Dhc.Auth.ExternalIdentity,
                 provider: "discord",
                 provider_subject: "discord-new-1"
               )

      assert principal_id == principal.id
    end

    test "provider subject takes precedence over a profile email matching another Principal" do
      linked = active_principal_fixture(email: "linked-owner@example.com")
      other = active_principal_fixture(email: "profile-email@example.com")

      identity = external_identity_fixture(linked, "discord-authoritative")

      assert {:ok, %{principal: signed_in}} =
               Auth.sign_in_with_discord(%{
                 "sub" => "discord-authoritative",
                 "email" => other.email,
                 "email_verified" => true,
                 "preferred_username" => "changed-name"
               })

      assert signed_in.id == linked.id

      persisted = Repo.get!(Dhc.Auth.ExternalIdentity, identity.id)
      assert persisted.principal_id == linked.id
      assert persisted.metadata == identity.metadata
      assert Auth.get_principal!(linked.id).email == "linked-owner@example.com"
      assert Auth.get_principal!(other.id).email == "profile-email@example.com"
    end

    test "rejects unverified, mismatched, and unknown email claims without linking" do
      active_principal_fixture(email: "eligible@example.com")

      claims = [
        %{
          "sub" => "discord-unverified",
          "email" => "eligible@example.com",
          "email_verified" => false
        },
        %{
          "sub" => "discord-mismatch",
          "email" => "different@example.com",
          "email_verified" => true
        },
        %{"sub" => "discord-no-email", "email_verified" => true}
      ]

      for claim <- claims do
        assert {:error, :invalid} = Auth.sign_in_with_discord(claim)
      end

      refute Repo.exists?(Dhc.Auth.ExternalIdentity)
    end

    test "rejects a new subject when the matching Principal already has Discord linked" do
      principal = active_principal_fixture(email: "already-linked@example.com")
      identity = external_identity_fixture(principal, "discord-existing")

      assert {:error, :invalid} =
               Auth.sign_in_with_discord(%{
                 "sub" => "discord-second",
                 "email" => principal.email,
                 "email_verified" => true
               })

      assert Repo.aggregate(Dhc.Auth.ExternalIdentity, :count) == 1

      assert Repo.get!(Dhc.Auth.ExternalIdentity, identity.id).provider_subject ==
               "discord-existing"
    end

    test "inactive Principals cannot sign in or gain a new link" do
      id = Ecto.UUID.generate()
      email = "inactive-discord@example.com"

      Dhc.MemberFixtures.member_fixture(%{auth_user_id: id, is_active: false, email: email})
      principal = principal_fixture(id: id, email: email)

      assert {:error, :invalid} =
               Auth.sign_in_with_discord(%{
                 "sub" => "discord-inactive-new",
                 "email" => email,
                 "email_verified" => true
               })

      refute Repo.exists?(Dhc.Auth.ExternalIdentity)

      external_identity_fixture(principal, "discord-inactive-linked")

      assert {:error, :invalid} =
               Auth.sign_in_with_discord(%{"sub" => "discord-inactive-linked"})

      refute Repo.exists?(from(t in PrincipalToken, where: t.context == "session"))
    end
  end

  describe "link_discord_identity/2" do
    test "an authenticated active Principal can link a Discord subject with a different email" do
      principal = active_principal_fixture(email: "principal-email@example.com")

      assert {:ok, identity} =
               Auth.link_discord_identity(principal, %{
                 "sub" => "discord-authenticated-link",
                 "email" => "different-discord-email@example.com",
                 "email_verified" => true,
                 "preferred_username" => "linked-member"
               })

      assert identity.principal_id == principal.id
      assert identity.provider == "discord"
      assert identity.provider_subject == "discord-authenticated-link"
      assert identity.metadata["email"] == "different-discord-email@example.com"
      assert Auth.get_principal!(principal.id).email == "principal-email@example.com"
      refute Repo.exists?(from(t in PrincipalToken, where: t.context == "session"))
    end

    test "cannot take a Discord subject already linked to another Principal" do
      owner = active_principal_fixture(email: "discord-owner@example.com")
      requester = active_principal_fixture(email: "discord-requester@example.com")
      external_identity_fixture(owner, "discord-owned-subject")

      assert {:error, :invalid} =
               Auth.link_discord_identity(requester, %{"sub" => "discord-owned-subject"})

      assert Repo.get_by!(Dhc.Auth.ExternalIdentity,
               provider: "discord",
               provider_subject: "discord-owned-subject"
             ).principal_id == owner.id
    end

    test "cannot bind a Discord subject reserved by an active Invitation Acceptance claim" do
      principal = active_principal_fixture(email: "claim-barrier@example.com")
      active_discord_claim_fixture("discord-acceptance-reserved")

      assert {:error, :invalid} =
               Auth.link_discord_identity(principal, %{
                 "sub" => "discord-acceptance-reserved"
               })

      assert {:error, :invalid} =
               Auth.sign_in_with_discord(%{
                 "sub" => "discord-acceptance-reserved",
                 "email" => principal.email,
                 "email_verified" => true
               })

      refute Repo.exists?(Dhc.Auth.ExternalIdentity)
    end
  end

  describe "load_session_principal/1" do
    test "returns roles and is_active when the Principal has a user_profile and roles" do
      # Build the Supabase/auth.users + user_profiles + member_profiles shape
      # with Dhc.MemberFixtures, then a Principal sharing the same UUID as
      # auth.users.id (the post-M1 invariant).
      auth_user_id = Ecto.UUID.generate()

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: "active@example.com"
      })

      # Grant the member a role.
      Repo.insert_all("user_roles", [
        [principal_id: Ecto.UUID.dump!(auth_user_id), role: "member"]
      ])

      principal = principal_fixture(id: auth_user_id, email: "active@example.com")

      assert {:ok, projection} = Auth.load_session_principal(principal)
      assert projection.principal.id == principal.id
      assert projection.is_active == true
      assert "member" in projection.roles
    end

    test "returns is_active=false when the user_profile is inactive" do
      auth_user_id = Ecto.UUID.generate()

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: false
      })

      principal = principal_fixture(id: auth_user_id)

      assert {:ok, projection} = Auth.load_session_principal(principal)
      assert projection.is_active == false
    end

    test "returns no_profile when the Principal has no user_profile" do
      principal = principal_fixture()
      assert {:error, :no_profile} = Auth.load_session_principal(principal)
    end
  end

  # Helpers

  defp oban_jobs_count do
    Repo.aggregate("oban_jobs", :count)
  end

  defp active_principal_fixture(attrs \\ []) do
    id = Ecto.UUID.generate()
    email = Keyword.get(attrs, :email, unique_principal_email())

    Dhc.MemberFixtures.member_fixture(%{
      auth_user_id: id,
      is_active: true,
      email: email
    })

    principal_fixture(%{
      id: id,
      email: email,
      confirmed_at: Keyword.get(attrs, :confirmed_at, DateTime.utc_now(:second))
    })
  end

  defp inactive_principal_fixture(attrs \\ []) do
    id = Ecto.UUID.generate()
    email = Keyword.get(attrs, :email, unique_principal_email())

    Dhc.MemberFixtures.member_fixture(%{
      auth_user_id: id,
      is_active: false,
      email: email
    })

    principal_fixture(%{
      id: id,
      email: email,
      confirmed_at: Keyword.get(attrs, :confirmed_at, DateTime.utc_now(:second))
    })
  end

  defp external_identity_fixture(principal, subject) do
    %Dhc.Auth.ExternalIdentity{}
    |> Dhc.Auth.ExternalIdentity.create_changeset(principal, %{
      provider: "discord",
      provider_subject: subject,
      metadata: %{"email" => "original-profile@example.com"}
    })
    |> Repo.insert!()
  end

  defp active_discord_claim_fixture(subject) do
    invitation =
      %Dhc.Invitations.Invitation{
        email: "claim-invitation-#{System.unique_integer([:positive])}@example.com",
        prospective_principal_id: Ecto.UUID.generate(),
        status: "pending",
        expires_at: DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second),
        invitation_type: "member",
        first_name: "Claim",
        last_name: "Owner",
        phone_number: "+353810000000",
        date_of_birth: ~D[1990-01-01]
      }
      |> Repo.insert!()

    attempt =
      %Dhc.Onboarding.InvitationAcceptanceAttempt{
        invitation_id: invitation.id,
        acceptance_data: %{}
      }
      |> Repo.insert!()

    continuation =
      %Dhc.Onboarding.InvitationAcceptanceDiscordContinuation{
        invitation_id: invitation.id,
        attempt_id: attempt.id,
        status: "verified",
        expires_at: DateTime.utc_now() |> DateTime.add(15, :minute) |> DateTime.truncate(:second),
        provider_subject: subject,
        subject_fingerprint: "fixture-fingerprint",
        display_metadata: %{}
      }
      |> Repo.insert!()

    %Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim{
      continuation_id: continuation.id,
      provider: "discord",
      provider_subject: subject
    }
    |> Repo.insert!()
  end
end
