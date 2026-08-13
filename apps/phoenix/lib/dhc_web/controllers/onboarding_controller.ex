defmodule DhcWeb.OnboardingController do
  use DhcWeb, :controller

  alias Dhc.Onboarding

  def start_acceptance(conn, %{
        "invitationId" => id,
        "email" => email,
        "dateOfBirth" => date_of_birth
      }) do
    protected_continuation_id =
      case get_req_header(conn, "x-onboarding-continuation") do
        [continuation_id] -> continuation_id
        _ -> nil
      end

    case Onboarding.start_acceptance(id, email, date_of_birth, protected_continuation_id) do
      {:ok, state} -> render_state(conn, state)
      {:error, _} -> restart_verification(conn)
    end
  end

  def start_acceptance(conn, _params), do: restart_verification(conn)

  # These opaque references are supplied only by the SvelteKit protected
  # browser-session cookie. The public API never accepts an Invitation id here.
  def show_acceptance(conn, _params) do
    with [continuation_id] <- get_req_header(conn, "x-onboarding-continuation"),
         {:ok, state} <- Onboarding.acceptance_state(continuation_id) do
      render_state(conn, state)
    else
      _ -> restart_verification(conn)
    end
  end

  defp render_state(conn, state) do
    json(conn, %{
      data: %{
        state: state.state,
        expiresAt: DateTime.to_iso8601(state.expires_at),
        continuationId: state.continuation_id
      }
    })
  end

  defp restart_verification(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{data: %{state: "restartVerification"}})
  end
end
