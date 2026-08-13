defmodule Mix.Tasks.Dhc.Discord.RosterCapture do
  @shortdoc "Captures the configured Discord guild roster for restricted review"

  use Mix.Task

  alias Dhc.Discord.RosterCapture

  @impl Mix.Task
  def run([]) do
    Mix.Task.run("app.start")
    reject_interactive_oauth_credentials!()

    options = %{
      token: required_env!("DISCORD_ROSTER_BOT_TOKEN"),
      guild_id: required_env!("DISCORD_ROSTER_GUILD_ID"),
      bot_application_id: required_env!("DISCORD_ROSTER_BOT_APPLICATION_ID"),
      actor_id: required_env!("DISCORD_ROSTER_ACTOR_ID"),
      package_dir: required_env!("DISCORD_ROSTER_PACKAGE_DIR"),
      package_key: required_env!("DISCORD_ROSTER_PACKAGE_KEY"),
      tool_revision: System.get_env("DISCORD_ROSTER_TOOL_REVISION", "unknown")
    }

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

  defp required_env!(name), do: System.get_env(name) || Mix.raise("#{name} is required")

  defp reject_interactive_oauth_credentials! do
    if System.get_env("DISCORD_CLIENT_SECRET") || System.get_env("DISCORD_CLIENT_ID") do
      Mix.raise("interactive Discord OAuth credentials are forbidden for roster capture")
    end
  end
end
