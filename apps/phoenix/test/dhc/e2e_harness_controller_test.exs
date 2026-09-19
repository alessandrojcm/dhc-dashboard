defmodule Dhc.E2EHarnessControllerTest do
  @moduledoc """
  HTTP mapping for harness fixture delete. Routes are compile-gated behind
  `E2E_SERVER=true`, so these tests invoke the controller action directly.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.E2EHarness
  alias Dhc.Repo
  alias DhcWeb.E2EHarnessController

  test "deleting a still-referenced structure fixture returns 409" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("ctrl-409-#{uniq}")

    result =
      E2EHarness.seed("inventoryStructure", %{
        "categoryName" => "E2E Ctrl Cat #{uniq}",
        "definitions" => [],
        "containerPath" => ["E2E Ctrl Cage #{uniq}", "Rack #{uniq}"],
        "actorId" => actor_id
      })

    [root, _leaf] = result.containers

    conn =
      harness_conn()
      |> E2EHarnessController.delete_fixture(%{
        "type" => "inventoryStructure",
        "id" => root.containerId
      })

    assert %{"errors" => %{"detail" => "still_referenced"}} = json_response(conn, 409)
  end

  test "status JSON keeps schemaVersion as a number" do
    conn = E2EHarnessController.status(harness_conn(), %{})

    assert %{"data" => %{"today" => today, "schemaVersion" => version}} = json_response(conn, 200)
    assert today =~ ~r/^\d{4}-\d{2}-\d{2}$/
    assert is_integer(version)
    assert version > 0
  end

  defp harness_conn do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-e2e-harness-key", Application.fetch_env!(:dhc, :e2e_harness_key))
  end

  defp principal_id!(slug) do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{email: "#{slug}@example.com"})
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
