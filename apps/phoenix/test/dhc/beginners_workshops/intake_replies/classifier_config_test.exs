defmodule Dhc.BeginnersWorkshops.IntakeReplies.ClassifierConfigTest do
  # Changes global application config, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias Dhc.BeginnersWorkshops.IntakeReplies.Classifier

  setup {Req.Test, :verify_on_exit!}

  test "a missing TypeSafe key is a closed error and sends nothing" do
    previous = Application.fetch_env!(:dhc, :typesafe_api_key)
    Application.delete_env(:dhc, :typesafe_api_key)
    on_exit(fn -> Application.put_env(:dhc, :typesafe_api_key, previous) end)

    assert {:error, :not_configured} =
             Classifier.classify("Please take me off the Waitlist", "contact_pay", [
               "leaving_waitlist"
             ])
  end
end
