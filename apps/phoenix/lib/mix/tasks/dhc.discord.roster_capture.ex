defmodule Mix.Tasks.Dhc.Discord.RosterCapture do
  @shortdoc "Captures the configured Discord guild roster for restricted review"

  use Mix.Task

  alias Dhc.Discord.RosterCapture

  @impl Mix.Task
  def run([]) do
    reject_interactive_oauth_credentials!()
    validate_execution_profile!()
    assert_isolated_runtime!()

    options = load_options!()
    start_minimum_runtime!()

    case RosterCapture.capture(options) do
      {:ok, result} ->
        Mix.shell().info(
          "capture_id=#{result.capture_id} count=#{result.count} digest=#{result.digest}"
        )

        Mix.shell().info("package=#{result.package_path}")
        Mix.shell().info(result.reconciliation)

      {:error, reason} ->
        Mix.raise("Discord roster capture failed safely: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("This task accepts no arguments")

  def load_options!(get_env \\ &System.get_env/1) do
    %{
      token: required_env!(get_env, "DISCORD_ROSTER_BOT_TOKEN"),
      guild_id: required_env!(get_env, "DISCORD_ROSTER_GUILD_ID"),
      bot_application_id: required_env!(get_env, "DISCORD_ROSTER_BOT_APPLICATION_ID"),
      execution_id: required_env!(get_env, "DISCORD_ROSTER_EXECUTION_ID"),
      package_dir: required_env!(get_env, "DISCORD_ROSTER_PACKAGE_DIR"),
      package_key: required_env!(get_env, "DISCORD_ROSTER_PACKAGE_KEY"),
      tool_revision: required_env!(get_env, "DISCORD_ROSTER_TOOL_REVISION")
    }
  end

  defp required_env!(get_env, name), do: get_env.(name) || Mix.raise("#{name} is required")

  def validate_execution_profile!(get_env \\ &System.get_env/1) do
    if get_env.("DISCORD_ROSTER_EXECUTION_PROFILE") == "approved-one-shot" do
      :ok
    else
      Mix.raise("DISCORD_ROSTER_EXECUTION_PROFILE must be approved-one-shot for isolated capture")
    end
  end

  defp assert_isolated_runtime! do
    if Process.whereis(Dhc.Supervisor) || Process.whereis(Dhc.Repo) do
      Mix.raise("Discord roster capture refuses to run inside the dashboard application runtime")
    end
  end

  defp start_minimum_runtime! do
    Enum.each([:ecto_sql, :postgrex, :req], fn application ->
      case Application.ensure_all_started(application) do
        {:ok, _started} -> :ok
        {:error, reason} -> Mix.raise("could not start #{application}: #{inspect(reason)}")
      end
    end)

    case Dhc.Repo.start_link() do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Mix.raise("could not start isolated roster receipt store: #{inspect(reason)}")
    end
  end

  defp reject_interactive_oauth_credentials! do
    if System.get_env("DISCORD_CLIENT_SECRET") || System.get_env("DISCORD_CLIENT_ID") do
      Mix.raise("interactive Discord OAuth credentials are forbidden for roster capture")
    end
  end
end
