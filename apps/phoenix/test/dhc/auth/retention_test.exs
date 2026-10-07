defmodule Dhc.Auth.RetentionTest do
  use Dhc.DataCase, async: true

  import Dhc.AuthFixtures

  alias Dhc.Auth.{PrincipalToken, Retention}
  alias Dhc.Auth.Workers.TokenRetentionWorker
  alias Dhc.Repo

  @now ~U[2026-10-07 12:00:00Z]
  @day 24 * 60 * 60

  setup do
    %{principal: principal_fixture()}
  end

  describe "prune/1 for principal_tokens" do
    test "keeps each context until its validity plus a one-day margin has passed", %{
      principal: principal
    } do
      for context <- ~w(login session socket) do
        validity = PrincipalToken.validity_seconds(context)
        boundary = validity + @day

        dead = insert_token!(principal, context, boundary + 1)
        at_boundary = insert_token!(principal, context, boundary)
        just_expired = insert_token!(principal, context, validity + 1)
        live = insert_token!(principal, context, 0)

        Retention.prune(now: @now)

        refute Repo.get(PrincipalToken, dead), "#{context} past the margin should be deleted"
        assert Repo.get(PrincipalToken, at_boundary)
        assert Repo.get(PrincipalToken, just_expired)
        assert Repo.get(PrincipalToken, live)
      end
    end

    test "derives each context's window from PrincipalToken" do
      assert PrincipalToken.validity_seconds("login") == 15 * 60
      assert PrincipalToken.validity_seconds("session") == 30 * @day
      assert PrincipalToken.validity_seconds("socket") == 60
    end

    test "deletes a backlog larger than one batch", %{principal: principal} do
      dead = for _ <- 1..5, do: insert_token!(principal, "socket", 2 * @day)
      live = insert_token!(principal, "socket", 0)

      assert %{principal_tokens: 5} = Retention.prune(now: @now, batch_size: 2)

      assert Enum.all?(dead, &is_nil(Repo.get(PrincipalToken, &1)))
      assert Repo.get(PrincipalToken, live)
    end
  end

  describe "prune/1 for auth_rate_limit_windows" do
    test "deletes windows that started more than a day ago, in batches" do
      for n <- 1..3, do: insert_window!("magic_link:ip:10.0.0.#{n}", @day + n)
      insert_window!("magic_link:email:kept@example.com", @day)
      insert_window!("magic_link:ip:10.0.0.9", 60 * 60)

      assert %{rate_limit_windows: 3} = Retention.prune(now: @now, batch_size: 2)

      assert Enum.sort(window_keys()) ==
               ["magic_link:email:kept@example.com", "magic_link:ip:10.0.0.9"]
    end
  end

  test "the worker runs a pass", %{principal: principal} do
    dead = insert_token!(principal, "login", 3 * @day, DateTime.utc_now(:second))

    assert :ok = perform_job(TokenRetentionWorker, %{})
    refute Repo.get(PrincipalToken, dead)
  end

  defp insert_token!(principal, context, age_seconds, now \\ @now) do
    {_raw, token} =
      case context do
        "login" -> PrincipalToken.build_magic_link_token(principal)
        "session" -> PrincipalToken.build_session_token(principal)
        "socket" -> PrincipalToken.build_socket_token(principal)
      end

    created_at = DateTime.add(now, -age_seconds)
    %{id: id} = Repo.insert!(%{token | created_at: created_at})
    id
  end

  defp insert_window!(key, age_seconds) do
    Repo.insert_all("auth_rate_limit_windows", [
      %{
        key: key,
        window_start: DateTime.add(@now, -age_seconds),
        count: 1,
        created_at: @now
      }
    ])
  end

  defp window_keys do
    Repo.all(from w in "auth_rate_limit_windows", select: w.key)
  end

  defp perform_job(worker, args) do
    Oban.Testing.perform_job(worker, args, repo: Repo)
  end
end
