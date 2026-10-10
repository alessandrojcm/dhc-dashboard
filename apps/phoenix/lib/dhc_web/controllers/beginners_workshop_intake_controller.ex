defmodule DhcWeb.BeginnersWorkshopIntakeController do
  @moduledoc """
  The `beginnersWorkshopIntake` slice (ALE-381): the person's Intake link.
  Public — the token in the path is the capability — and served through the
  `:intake_link` pipeline (`Referrer-Policy: no-referrer`, redacted request
  log). Every response is the closed `Dhc.BeginnersWorkshops.IntakePage`
  view or a refusal; never an id or a Stripe object (the Checkout URL is the
  one Stripe value, and only as the redirect target).
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopIntakeHTTP

  alias Dhc.BeginnersWorkshops

  @doc "GET /beginners/intake/{token}"
  def show(conn, %{"token" => token}) do
    with {:ok, page} <- BeginnersWorkshops.intake_page(token) do
      render(conn, :show, page: page)
    end
  end

  @doc "POST /beginners/intake/{token}/payment — takes the Seat Hold; answers the Checkout URL."
  def start_payment(conn, %{"token" => token}) do
    case BeginnersWorkshops.execute({:intake_link, token}, :start_payment) do
      {:ok, %{checkout_url: url}} -> render(conn, :checkout, checkout_url: url)
      # A malformed token is refused before any read; it is still just an
      # unknown link.
      {:error, :forbidden} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  POST /beginners/intake/{token}/confirm — a Carried Fee holder confirms
  their place (ALE-388); answers the page.
  """
  def confirm(conn, %{"token" => token}) do
    case BeginnersWorkshops.execute({:intake_link, token}, :confirm) do
      {:ok, _outcome} ->
        with {:ok, page} <- BeginnersWorkshops.intake_page(token),
             do: render(conn, :show, page: page)

      {:error, :forbidden} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  POST /beginners/intake/{token}/return — the Checkout success return:
  completes the payment from the session retrieved server-side, then
  answers the page. A completion that cannot finish yet (Stripe unreachable,
  session still open) leaves the page `payment_in_progress`.
  """
  def return_from_checkout(conn, %{"token" => token} = params) do
    session_id = params |> Map.get("sessionId") |> session_id()

    with {:ok, _page} <- BeginnersWorkshops.intake_page(token) do
      if session_id, do: _ = BeginnersWorkshops.execute(:stripe, {:complete_payment, session_id})

      with {:ok, page} <- BeginnersWorkshops.intake_page(token, returned_session: session_id) do
        render(conn, :show, page: page)
      end
    end
  end

  # A Checkout Session id (`cs_…`); anything else is ignored.
  defp session_id("cs_" <> _rest = id) when byte_size(id) <= 255, do: id
  defp session_id(_other), do: nil
end
