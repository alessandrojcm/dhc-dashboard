defmodule Dhc.TypeSafeStub do
  @moduledoc """
  Builds TypeSafe `/v1/systemone` responses for `Req.Test` plugs (ALE-410).

  Tests stub TypeSafe with `Req.Test.stub(Dhc.TypeSafe, plug)` or
  `Req.Test.expect/3`; `config/test.exs` routes `Dhc.TypeSafe.Client` there.
  Every answer is built from the request's own questions, so a stub can only
  return a response the real API could return for that request.
  """

  @doc "The decoded JSON request body."
  @spec request(Plug.Conn.t()) :: {map(), Plug.Conn.t()}
  def request(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  @doc """
  The reply text inside the request's `state` (what follows "Person's new
  reply:").
  """
  @spec reply_text(map()) :: String.t()
  def reply_text(%{"state" => state}) do
    [_header, text] = String.split(state, "Person's new reply:\n", parts: 2)
    text
  end

  @doc """
  A well-formed answer choosing `intent` with `confidence`, spreading the rest
  of the probability over the other offered options.
  """
  @spec answer(map(), String.t(), number(), number(), keyword()) :: map()
  def answer(request, intent, confidence, money_back, opts \\ []) do
    options = request |> get_in(["questions", "intent", "criteria"]) |> Map.keys()
    others = List.delete(options, intent)
    rest = if others == [], do: 0.0, else: (1 - confidence) / length(others)

    %{
      "model" => Keyword.get(opts, :model, "jev-1.13.0"),
      "answers" => %{
        "intent" => %{
          "type" => "choice",
          "choice" => intent,
          "confidence" => confidence,
          "probabilities" => Map.new(options, &{&1, if(&1 == intent, do: confidence, else: rest)})
        },
        "money_back" => %{"type" => "noul", "noul" => money_back}
      },
      "usage" => %{"input_tokens" => 100, "output_tokens" => 10}
    }
  end

  @doc """
  A plug that answers each request by looking its reply text up in `table`
  (`%{reply_text => {intent, confidence, money_back}}`).
  """
  @spec by_reply(%{String.t() => {String.t(), number(), number()}}) :: (Plug.Conn.t() ->
                                                                          Plug.Conn.t())
  def by_reply(table) do
    fn conn ->
      {request, conn} = request(conn)
      {intent, confidence, money_back} = Map.fetch!(table, reply_text(request))
      Req.Test.json(conn, answer(request, intent, confidence, money_back))
    end
  end
end
