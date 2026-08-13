defmodule Dhc.Discord.RosterCapture.Sleeper do
  @moduledoc false
  def sleep(milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    Process.sleep(milliseconds)
    :ok
  end
end
