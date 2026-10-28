defmodule Dhc.Discord.GuildJoinProtocolTest do
  use ExUnit.Case, async: false

  alias Dhc.Discord.Adapter.Nostrum, as: LiveAdapter

  setup do
    start_supervised!(Nostrum.Api.RatelimiterGroup)
    :ok
  end

  test "optional nickname permissions cannot prevent joining the guild" do
    start_supervised!(
      {Dhc.Discord.RatelimiterStub,
       owner: self(),
       respond: fn request ->
         if Map.has_key?(request.body, :nick) do
           {:error,
            %Nostrum.Error.ApiError{
              status_code: 403,
              response: %{code: 50_013, message: "Missing Permissions"}
            }}
         else
           {:ok, ~s({"user":{"id":"222"},"roles":[]})}
         end
       end}
    )

    assert {:ok, :added} = LiveAdapter.add_guild_member("111", "222", "synthetic-token", "Ada")
    assert_receive {:discord_request, %{method: :put, body: %{nick: "Ada"}}}
    assert_receive {:discord_request, %{method: :put, body: body}}
    assert body == %{access_token: "synthetic-token"}
  end

  for {status, code} <- [{401, 0}, {403, 50_001}, {403, 40_007}] do
    test "#{status}/#{code} is not retried as a nickname permission failure" do
      error = %Nostrum.Error.ApiError{
        status_code: unquote(status),
        response: %{"code" => unquote(code), "message" => "Denied"}
      }

      start_supervised!(
        {Dhc.Discord.RatelimiterStub, owner: self(), respond: fn _ -> {:error, error} end}
      )

      assert {:error, %Dhc.Discord.ApiError{code: unquote(code)}} =
               LiveAdapter.add_guild_member("111", "222", "synthetic-token", "Ada")

      assert_receive {:discord_request, _}
      refute_receive {:discord_request, _}
    end
  end

  test "a missing join permission is returned after exactly one nickname-free attempt" do
    error = %Nostrum.Error.ApiError{status_code: 403, response: %{code: 50_013}}

    start_supervised!(
      {Dhc.Discord.RatelimiterStub, owner: self(), respond: fn _ -> {:error, error} end}
    )

    assert {:error, %Dhc.Discord.ApiError{status: 403, code: 50_013}} =
             LiveAdapter.add_guild_member("111", "222", "synthetic-token", "Ada")

    assert_receive {:discord_request, %{body: %{nick: "Ada"}}}
    assert_receive {:discord_request, %{body: %{access_token: "synthetic-token"} = body}}
    refute Map.has_key?(body, :nick)
    refute_receive {:discord_request, _}
  end

  test "an already-member response needs no fallback" do
    start_supervised!({Dhc.Discord.RatelimiterStub, owner: self(), respond: fn _ -> {:ok} end})

    assert {:ok, :already_member} =
             LiveAdapter.add_guild_member("111", "222", "synthetic-token", "Ada")

    assert_receive {:discord_request, _}
    refute_receive {:discord_request, _}
  end
end
