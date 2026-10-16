defmodule Dhc.ResendReceivingStub do
  @moduledoc """
  Test-only router for Resend's receiving API (ALE-409), installed with
  `Req.Test.stub(Dhc.Resend, ...)` (`config/test.exs` points
  `Dhc.Resend.Receiving` at `{Req.Test, Dhc.Resend}`).

  `stub/2` serves one received email: `GET /emails/receiving/:id`, its
  attachment list, every attachment download and the raw `.eml` download.

  Options:

    * `:email` — fields merged into the received email (`html`, `text`,
      `from`, `subject`, …);
    * `:attachments` — `[{meta, content}]`; `meta` is merged into the listed
      attachment (`filename`, `content_type`, `content_disposition`,
      `content_id`; `size` defaults to the content's);
    * `:raw` — the raw message (default a small `.eml`); `nil` for none;
    * `:fail` — routes that answer 500: any of `:email`, `:attachments`,
      `:download`, `:raw`.

  `signed_headers/2` signs a webhook body the way Resend does.
  """

  alias Dhc.Resend.Webhook

  @raw_host "https://resend-raw.test"
  @cdn_host "https://resend-cdn.test"

  def stub(email_id, opts \\ []) do
    fail = Keyword.get(opts, :fail, [])
    attachments = Keyword.get(opts, :attachments, [])
    raw = Keyword.get(opts, :raw, "From: person@example.com\r\nSubject: Re: hi\r\n\r\nHello")

    listed =
      attachments
      |> Enum.with_index(1)
      |> Enum.map(fn {{meta, content}, index} ->
        id = "att-#{index}"

        {id,
         Map.merge(
           %{
             "id" => id,
             "filename" => "file-#{index}.bin",
             "content_type" => "application/octet-stream",
             "content_disposition" => "attachment",
             "content_id" => nil,
             "size" => byte_size(content),
             "download_url" => "#{@cdn_host}/att/#{id}"
           },
           meta
         ), content}
      end)

    email =
      Map.merge(
        %{
          "object" => "email",
          "id" => email_id,
          "from" => "person@example.com",
          "to" => ["token@reply.example.test"],
          "subject" => "Re: Your workshop place",
          "html" => "<p>I can't make it, sorry.</p>",
          "text" => "I can't make it, sorry.",
          "html_format" => "cid",
          "headers" => %{"from" => "Person <person@example.com>"},
          "raw" => raw && %{"download_url" => "#{@raw_host}/raw/#{email_id}"}
        },
        Keyword.get(opts, :email, %{})
      )

    Req.Test.stub(Dhc.Resend, fn conn ->
      route(conn, email_id, email, listed, raw, fail)
    end)
  end

  defp route(conn, id, email, listed, raw, fail) do
    case {conn.request_path, raw} do
      {"/emails/receiving/" <> rest, _raw} -> receiving(conn, id, rest, email, listed, fail)
      {"/raw/" <> ^id, raw} when is_binary(raw) -> serve(conn, :raw, raw, fail)
      {"/att/" <> att_id, _raw} -> attachment(conn, att_id, listed, fail)
      _other -> Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  defp receiving(conn, id, rest, email, listed, fail) do
    attachments = "#{id}/attachments"

    case rest do
      ^attachments ->
        list = %{
          "object" => "list",
          "has_more" => false,
          "data" => Enum.map(listed, &elem(&1, 1))
        }

        serve(conn, :attachments, list, fail)

      ^id ->
        serve(conn, :email, email, fail)

      _other ->
        Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  defp attachment(conn, att_id, listed, fail) do
    case List.keyfind(listed, att_id, 0) do
      {_id, _meta, content} -> serve(conn, :download, content, fail)
      nil -> error(conn)
    end
  end

  defp serve(conn, route, body, fail) do
    cond do
      route in fail -> error(conn)
      is_binary(body) -> Plug.Conn.send_resp(conn, 200, body)
      true -> Req.Test.json(conn, body)
    end
  end

  defp error(conn), do: Plug.Conn.send_resp(conn, 500, "boom")

  @doc "Svix headers for `payload`, signed with the test secret at `timestamp`."
  def signed_headers(payload, timestamp \\ System.system_time(:second)) do
    id = "msg_#{System.unique_integer([:positive])}"
    secret = Application.fetch_env!(:dhc, :resend_webhook_secret)

    [
      {"svix-id", id},
      {"svix-timestamp", Integer.to_string(timestamp)},
      {"svix-signature", Webhook.sign(payload, id, timestamp, secret)}
    ]
  end
end
