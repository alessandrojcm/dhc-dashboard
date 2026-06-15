defmodule Dhc.Discord.WorkerTest do
  use ExUnit.Case, async: true

  alias Dhc.Discord.Worker

  describe "perform/1 with valid args in test environment" do
    test "succeeds and skips actual Discord send" do
      # Test env is configured to skip sends, so we test the happy path
      # without hitting the real Discord API
      args = %{
        "message" => "Workshop starts tomorrow!",
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "created"
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    end

    test "succeeds for all announcement types" do
      for type <- ["created", "status_changed", "time_changed", "location_changed"] do
        args = %{
          "message" => "Workshop update",
          "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
          "announcement_type" => type
        }

        assert Worker.perform(%Oban.Job{args: args}) == :ok
      end
    end
  end

  describe "perform/1 with invalid args" do
    test "returns error when message is missing" do
      args = %{
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "created"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing message" in errors
    end

    test "returns error when message is empty string" do
      args = %{
        "message" => "",
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "created"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing message" in errors
    end

    test "returns error when workshop_id is missing" do
      args = %{
        "message" => "Hello world",
        "announcement_type" => "created"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing workshop_id" in errors
    end

    test "returns error when announcement_type is invalid" do
      args = %{
        "message" => "Hello world",
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "invalid_type"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "invalid announcement_type" in errors
    end

    test "returns error when announcement_type is missing" do
      args = %{
        "message" => "Hello world",
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing announcement_type" in errors
    end

    test "accumulates multiple validation errors" do
      args = %{}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing message" in errors
      assert "missing workshop_id" in errors
      assert "missing announcement_type" in errors
      assert "invalid announcement_type" in errors
    end
  end

  describe "perform/1 in prod environment" do
    setup do
      original_env = Application.get_env(:dhc, :environment)
      original_url = Application.get_env(:dhc, :discord_webhook_url)

      Application.put_env(:dhc, :environment, :prod)
      Application.put_env(:dhc, :discord_webhook_url, "https://discord.example.com/webhook/test")

      on_exit(fn ->
        Application.put_env(:dhc, :environment, original_env)
        Application.put_env(:dhc, :discord_webhook_url, original_url)
      end)

      :ok
    end

    test "returns error when Discord API returns non-2xx" do
      # Bypass simulates a failed Discord API response
      bypass = Bypass.open()

      Application.put_env(
        :dhc,
        :discord_webhook_url,
        "http://localhost:#{bypass.port}/webhook"
      )

      Bypass.expect(bypass, "POST", "/webhook", fn conn ->
        Plug.Conn.send_resp(conn, 429, "{\"message\": \"Rate limited\"}")
      end)

      args = %{
        "message" => "Workshop starts tomorrow!",
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "created"
      }

      assert {:error, {:discord_api, 429}} = Worker.perform(%Oban.Job{args: args})
    end

    test "returns error when Discord webhook URL is not configured" do
      Application.put_env(:dhc, :discord_webhook_url, nil)

      args = %{
        "message" => "Workshop starts tomorrow!",
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "created"
      }

      assert {:error, :webhook_url_not_configured} = Worker.perform(%Oban.Job{args: args})
    end

    test "returns error when Discord webhook URL is empty string" do
      Application.put_env(:dhc, :discord_webhook_url, "")

      args = %{
        "message" => "Workshop starts tomorrow!",
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "created"
      }

      assert {:error, :webhook_url_not_configured} = Worker.perform(%Oban.Job{args: args})
    end

    test "sends message successfully when Discord API returns 2xx" do
      bypass = Bypass.open()

      Application.put_env(
        :dhc,
        :discord_webhook_url,
        "http://localhost:#{bypass.port}/webhook"
      )

      Bypass.expect(bypass, "POST", "/webhook", fn conn ->
        Plug.Conn.send_resp(conn, 204, "")
      end)

      args = %{
        "message" => "Workshop starts tomorrow!",
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "created"
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    end

    test "sends @everyone mention in payload" do
      bypass = Bypass.open()

      Application.put_env(
        :dhc,
        :discord_webhook_url,
        "http://localhost:#{bypass.port}/webhook"
      )

      Bypass.expect(bypass, "POST", "/webhook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert String.contains?(payload["content"], "Hey @everyone!")
        assert String.contains?(payload["content"], "Workshop starts tomorrow!")
        assert payload["allowed_mentions"]["parse"] == ["everyone"]

        Plug.Conn.send_resp(conn, 204, "")
      end)

      args = %{
        "message" => "Workshop starts tomorrow!",
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "created"
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    end

    test "returns error on HTTP connection failure" do
      # Use a URL that will fail to connect
      Application.put_env(
        :dhc,
        :discord_webhook_url,
        "http://localhost:1/invalid-webhook"
      )

      args = %{
        "message" => "Workshop starts tomorrow!",
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "created"
      }

      assert {:error, {:http_error, _}} = Worker.perform(%Oban.Job{args: args})
    end
  end
end
