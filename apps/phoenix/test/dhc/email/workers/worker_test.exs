defmodule Dhc.Email.WorkerTest do
  use ExUnit.Case, async: false

  alias Dhc.Email.Worker

  describe "perform/1 with valid args in test environment" do
    test "succeeds and skips actual email send" do
      # Test env is configured to skip sends, so we test the happy path
      # without hitting the real Loops API
      args = %{
        "email" => "user@example.com",
        "transactional_id" => "inviteMember",
        "data_variables" => %{"name" => "Alice", "inviteLink" => "https://example.com/invite"}
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    end

    test "succeeds for workshopAnnouncement transactional type" do
      args = %{
        "email" => "user@example.com",
        "transactional_id" => "workshopAnnouncement",
        "data_variables" => %{
          "workshopTitle" => "HEMA Open Session",
          "date" => "2024-01-15"
        }
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    end

    test "succeeds without data_variables" do
      args = %{
        "email" => "user@example.com",
        "transactional_id" => "inviteMember"
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    end

    test "succeeds with numeric data variable values" do
      args = %{
        "email" => "user@example.com",
        "transactional_id" => "workshopAnnouncement",
        "data_variables" => %{"count" => 5, "name" => "Bob"}
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    end
  end

  describe "perform/1 with invalid args" do
    test "returns error when email is missing" do
      args = %{
        "transactional_id" => "inviteMember"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing email" in errors
    end

    test "returns error when email is empty string" do
      args = %{
        "email" => "",
        "transactional_id" => "inviteMember"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing email" in errors
    end

    test "returns error when email has invalid format" do
      args = %{
        "email" => "not-an-email",
        "transactional_id" => "inviteMember"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "invalid email format" in errors
    end

    test "returns error when transactional_id is missing" do
      args = %{
        "email" => "user@example.com"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing transactional_id" in errors
    end

    test "returns error when transactional_id is invalid" do
      args = %{
        "email" => "user@example.com",
        "transactional_id" => "unknownTemplate"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "invalid transactional_id" in errors
    end

    test "returns error when data_variables has non-string/number values" do
      args = %{
        "email" => "user@example.com",
        "transactional_id" => "inviteMember",
        "data_variables" => %{"link" => %{"nested" => "object"}}
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "data_variables values must be strings or numbers" in errors
    end

    test "accumulates multiple validation errors" do
      args = %{}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing email" in errors
      assert "missing transactional_id" in errors
      assert "invalid transactional_id" in errors
    end
  end

  describe "perform/1 in prod environment" do
    setup do
      original_env = Application.get_env(:dhc, :environment)
      original_key = Application.get_env(:dhc, :loops_api_key)

      Application.put_env(:dhc, :environment, :prod)

      on_exit(fn ->
        Application.put_env(:dhc, :environment, original_env)
        Application.put_env(:dhc, :loops_api_key, original_key)
      end)

      :ok
    end

    test "returns error when Loops API returns non-2xx" do
      bypass = Bypass.open()

      Application.put_env(:dhc, :loops_api_key, "test-api-key")

      Bypass.expect(bypass, "POST", "/api/v1/transactional", fn conn ->
        Plug.Conn.send_resp(conn, 400, "{\"error\": \"Invalid request\"}")
      end)

      # Temporarily override the API URL to point to Bypass
      original_url = Application.get_env(:dhc, :loops_api_url)

      Application.put_env(
        :dhc,
        :loops_api_url,
        "http://localhost:#{bypass.port}/api/v1/transactional"
      )

      args = %{
        "email" => "user@example.com",
        "transactional_id" => "inviteMember",
        "data_variables" => %{"name" => "Alice"}
      }

      assert {:error, {:loops_api, 400}} = Worker.perform(%Oban.Job{args: args})
    after
      Application.delete_env(:dhc, :loops_api_url)
    end

    test "returns error when Loops API key is not configured" do
      Application.put_env(:dhc, :loops_api_key, nil)

      args = %{
        "email" => "user@example.com",
        "transactional_id" => "inviteMember"
      }

      assert {:error, :api_key_not_configured} = Worker.perform(%Oban.Job{args: args})
    end

    test "returns error when Loops API key is empty string" do
      Application.put_env(:dhc, :loops_api_key, "")

      args = %{
        "email" => "user@example.com",
        "transactional_id" => "inviteMember"
      }

      assert {:error, :api_key_not_configured} = Worker.perform(%Oban.Job{args: args})
    end

    test "sends email successfully when Loops API returns 2xx" do
      bypass = Bypass.open()

      Application.put_env(:dhc, :loops_api_key, "test-api-key")

      Bypass.expect(bypass, "POST", "/api/v1/transactional", fn conn ->
        Plug.Conn.send_resp(conn, 200, "{\"success\": true}")
      end)

      original_url = Application.get_env(:dhc, :loops_api_url)

      Application.put_env(
        :dhc,
        :loops_api_url,
        "http://localhost:#{bypass.port}/api/v1/transactional"
      )

      args = %{
        "email" => "user@example.com",
        "transactional_id" => "inviteMember",
        "data_variables" => %{"name" => "Alice"}
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    after
      Application.delete_env(:dhc, :loops_api_url)
    end

    test "sends correct payload to Loops API" do
      bypass = Bypass.open()

      Application.put_env(:dhc, :loops_api_key, "test-api-key")

      Bypass.expect(bypass, "POST", "/api/v1/transactional", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload["email"] == "user@example.com"
        assert payload["transactionalId"] == "inviteMember"
        assert payload["dataVariables"]["name"] == "Alice"

        Plug.Conn.send_resp(conn, 200, "{\"success\": true}")
      end)

      original_url = Application.get_env(:dhc, :loops_api_url)

      Application.put_env(
        :dhc,
        :loops_api_url,
        "http://localhost:#{bypass.port}/api/v1/transactional"
      )

      args = %{
        "email" => "user@example.com",
        "transactional_id" => "inviteMember",
        "data_variables" => %{"name" => "Alice"}
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    after
      Application.delete_env(:dhc, :loops_api_url)
    end

    test "sends authorization header with Bearer token" do
      bypass = Bypass.open()

      Application.put_env(:dhc, :loops_api_key, "my-secret-key")

      Bypass.expect(bypass, "POST", "/api/v1/transactional", fn conn ->
        assert ["Bearer my-secret-key"] = Plug.Conn.get_req_header(conn, "authorization")

        Plug.Conn.send_resp(conn, 200, "{\"success\": true}")
      end)

      original_url = Application.get_env(:dhc, :loops_api_url)

      Application.put_env(
        :dhc,
        :loops_api_url,
        "http://localhost:#{bypass.port}/api/v1/transactional"
      )

      args = %{
        "email" => "user@example.com",
        "transactional_id" => "inviteMember"
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    after
      Application.delete_env(:dhc, :loops_api_url)
    end

    test "returns error on HTTP connection failure" do
      # Use a URL that will fail to connect
      Application.put_env(:dhc, :loops_api_key, "test-api-key")

      # Use a port that's not listening
      original_url = Application.get_env(:dhc, :loops_api_url)
      Application.put_env(:dhc, :loops_api_url, "http://localhost:1/invalid-api")

      args = %{
        "email" => "user@example.com",
        "transactional_id" => "inviteMember"
      }

      assert {:error, {:http_error, _}} = Worker.perform(%Oban.Job{args: args})
    after
      Application.delete_env(:dhc, :loops_api_url)
    end
  end
end
