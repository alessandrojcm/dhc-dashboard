defmodule Dhc.Notifications.Workers.KeyedCreateWorkerTest do
  @moduledoc """
  ALE-298: retried keyed notification creation after a loan command commits.
  """

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.Principal
  alias Dhc.Notifications.Notification
  alias Dhc.Notifications.Workers.KeyedCreateWorker
  alias Dhc.Repo

  setup do
    original = Application.get_env(:dhc, :keyed_notification_create)

    on_exit(fn ->
      if original,
        do: Application.put_env(:dhc, :keyed_notification_create, original),
        else: Application.delete_env(:dhc, :keyed_notification_create)
    end)

    :ok
  end

  test "creates a keyed row for each recipient" do
    first = principal()
    second = principal()

    assert :ok =
             perform_job(KeyedCreateWorker, %{
               "principal_ids" => [first, second],
               "key" => "inventory:loan:test:approved",
               "body" => "Approved."
             })

    rows = Repo.all(Notification)
    assert Enum.sort(Enum.map(rows, & &1.principal_id)) == Enum.sort([first, second])
    assert Enum.all?(rows, &(&1.notification_key == "inventory:loan:test:approved"))
  end

  test "retries after an injected create_keyed failure and then creates the row" do
    recipient = principal()
    args = %{"principal_ids" => [recipient], "key" => "inventory:loan:test:retry", "body" => "Hi"}

    Application.put_env(:dhc, :keyed_notification_create, fn _id, _key, _body ->
      {:error, :injected}
    end)

    assert {:error, :injected} = perform_job(KeyedCreateWorker, args)
    assert Repo.all(Notification) == []

    Application.delete_env(:dhc, :keyed_notification_create)
    assert :ok = perform_job(KeyedCreateWorker, args)
    assert [%Notification{principal_id: ^recipient}] = Repo.all(Notification)
  end

  defp principal do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "keyed-worker-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
