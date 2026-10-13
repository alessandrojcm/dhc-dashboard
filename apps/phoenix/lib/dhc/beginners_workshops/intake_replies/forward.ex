defmodule Dhc.BeginnersWorkshops.IntakeReplies.Forward do
  @moduledoc """
  Builds the one forward of an Intake Reply to the club inbox (ALE-409,
  ADR 0030). Pure: `IntakeReplies.forward/2` fetches the received email
  and sends what this module builds through `Dhc.Email.Mailer` (the
  Swoosh seam, ADR 0021).

  Every forward is sent from the club sender to `INTAKE_REPLY_FORWARD_TO`
  (`config :dhc, :intake_reply_forward_to`, default
  `contact@dublinhemaclub.com`), with Reply-To set to the reply's original
  From so a coordinator can answer the person directly, a subject tag
  (`[Needs you]` or `[Unrecognised]`), and the idempotency key
  `intake-reply-forward:<resend email id>`. A one-line, HTML-escaped banner
  — who replied, which email they answered, and a link to their workshop's
  Manage page (or the Waitlist) — sits above the original. It comes in three
  shapes, from best to barest:

    * `rebuilt/3` — the original HTML and text, with every attachment
      re-attached (inline ones keep their `content_id`, so `cid:` images
      still render);
    * `with_original/3` — the banner, with the raw message attached as
      `forwarded_message.eml` (`message/rfc822`), when the reply cannot be
      rebuilt or would exceed Resend's 40 MB limit;
    * `banner_only/3` — the banner alone, noting the original is kept in
      Resend for 30 days, when even that is too large or the reply could not
      be read at all.
  """

  alias Swoosh.{Attachment, Email}

  # Resend's limit for one email, attachments included (base64-encoded).
  @max_bytes 40_000_000

  @email_labels %{
    "contact_pay" => "Place offer: payment needed",
    "contact_confirm" => "Place offer: use workshop credit",
    "place_confirmed_paid" => "Place confirmed — paid",
    "place_confirmed_carried" => "Place confirmed: credit used",
    "pre_workshop" => "Pre-workshop info",
    "rescheduled" => "Workshop rescheduled",
    "follow_up" => "Follow-up",
    "declined" => "Declined",
    "deferred" => "Moved to a later workshop",
    "cancelled_with_refund" => "Place cancelled: refund requested",
    "withdrawn_refunded" => "Withdrawn — refunded",
    "withdrawn_forfeited" => "Withdrawn: payment kept",
    "carried_fee_refunded" => "Workshop credit: refund requested",
    "payment_refunded" => "Automatic refund requested",
    "cancelled_paid" => "Workshop cancelled — paid",
    "cancelled_unpaid" => "Workshop cancelled — unpaid"
  }

  @typedoc """
  Who the reply came from, as the banner names them: `nil` for a reply to an
  address that resolved to nothing.
  """
  @type person :: %{
          name: String.t(),
          email_type: String.t(),
          workshop_id: Ecto.UUID.t() | nil
        }

  @type context :: %{
          resend_email_id: String.t(),
          tag: :needs_you | :unrecognised,
          person: person() | nil
        }

  @type note :: :too_large | :unavailable

  @doc "Resend's size limit for one email."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The banner's label for each Intake Email type (staff copy)."
  @spec email_labels() :: %{String.t() => String.t()}
  def email_labels, do: @email_labels

  @doc "The forward's subject tag."
  @spec tag(context()) :: String.t()
  def tag(%{tag: :needs_you}), do: "[Needs you]"
  def tag(%{tag: :unrecognised}), do: "[Unrecognised]"

  @doc """
  The size the rebuilt forward would have: its bodies plus every attachment
  as base64, from the sizes Resend lists (so nothing is downloaded to learn
  it is too large).
  """
  @spec rebuilt_bytes(map(), [map()]) :: non_neg_integer()
  def rebuilt_bytes(received, attachments) do
    text = received["text"] || ""

    # A text-only reply is also sent as HTML (escaped, in a `<pre>`).
    html =
      case received["html"] do
        html when is_binary(html) and html != "" -> html
        _none -> escape(text)
      end

    bodies = byte_size(html) + byte_size(text)

    attachments
    |> Enum.map(fn attachment -> base64_size(attachment["size"]) end)
    |> Enum.sum()
    |> Kernel.+(bodies)
  end

  @doc "The size of an attached raw message, as base64."
  @spec original_bytes(binary()) :: non_neg_integer()
  def original_bytes(raw), do: base64_size(byte_size(raw))

  @doc "The forward rebuilt from the received email and its downloaded attachments."
  @spec rebuilt(context(), map(), [{map(), binary()}]) :: Email.t()
  def rebuilt(context, received, attachments) do
    banner = banner(context, nil)

    # `Email.attachment/2` prepends, so add them last-first to keep the order.
    attachments
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.reduce(base(context, received), fn {{meta, content}, index}, email ->
      Email.attachment(email, attachment(meta, content, index))
    end)
    |> Email.html_body(with_banner_html(banner, received["html"], received["text"]))
    |> Email.text_body(with_banner_text(banner, received["text"]))
  end

  @doc "The banner with the raw message attached as `forwarded_message.eml`."
  @spec with_original(context(), map() | nil, binary()) :: Email.t()
  def with_original(context, received, raw) when is_binary(raw) do
    banner =
      banner(context, "The reply could not be rebuilt, so the original message is attached.")

    context
    |> base(received)
    |> Email.attachment(
      Attachment.new({:data, raw},
        filename: "forwarded_message.eml",
        content_type: "message/rfc822"
      )
    )
    |> Email.html_body(banner_html(banner))
    |> Email.text_body(banner_text(banner))
  end

  @doc "The banner alone, noting where the original is kept."
  @spec banner_only(context(), map() | nil, note()) :: Email.t()
  def banner_only(context, received, note) do
    banner = banner(context, note_text(note, context.resend_email_id))

    context
    |> base(received)
    |> Email.html_body(banner_html(banner))
    |> Email.text_body(banner_text(banner))
  end

  defp base(context, received) do
    received = received || %{}

    Email.new()
    |> Email.from(email_from())
    |> Email.to(forward_to())
    |> reply_to(received["from"])
    |> Email.subject("#{tag(context)} #{subject(received["subject"])}")
    |> Email.put_provider_option(
      :idempotency_key,
      "intake-reply-forward:#{context.resend_email_id}"
    )
  end

  defp reply_to(email, from) when is_binary(from) and from != "", do: Email.reply_to(email, from)
  defp reply_to(email, _from), do: email

  defp subject(subject) when is_binary(subject) do
    case String.trim(subject) do
      "" -> "(no subject)"
      trimmed -> trimmed
    end
  end

  defp subject(_subject), do: "(no subject)"

  defp attachment(meta, content, index) do
    inline? = meta["content_disposition"] == "inline" and is_binary(meta["content_id"])

    Attachment.new({:data, content},
      filename: meta["filename"] || "attachment-#{index}",
      content_type: meta["content_type"] || "application/octet-stream",
      type: if(inline?, do: :inline, else: :attachment),
      cid: if(inline?, do: meta["content_id"])
    )
  end

  # ── Banner ──────────────────────────────────────────────────────

  # `{sentence, link | nil, note | nil}`: the one line, then an optional note.
  defp banner(%{person: nil}, note),
    do:
      {"This reply was sent to a reply address that matches nobody, for example " <>
         "because the person has since been deleted.", nil, note}

  defp banner(%{person: person}, note) do
    label = Map.get(@email_labels, person.email_type, person.email_type)

    {"Reply from #{person.name} to the “#{label}” email.", link(person), note}
  end

  defp link(%{workshop_id: nil}),
    do: {"Open the Waitlist", "#{app_url()}/dashboard/beginners-workshop/waitlist"}

  defp link(%{workshop_id: workshop_id}),
    do:
      {"Open the workshop's Manage page",
       "#{app_url()}/dashboard/beginners-workshop/workshops/#{workshop_id}"}

  defp note_text(:too_large, id),
    do:
      "The original message is too large to forward. It is kept in Resend for 30 days " <>
        "(received email #{id})."

  defp note_text(:unavailable, id),
    do:
      "The reply could not be forwarded in full. The original is kept in Resend for 30 days " <>
        "(received email #{id})."

  defp banner_text({sentence, link, note}) do
    [sentence, link && "#{elem(link, 0)}: #{elem(link, 1)}", note]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp banner_html({sentence, link, note}) do
    link_html =
      case link do
        {label, url} -> ~s( <a href="#{escape(url)}">#{escape(label)}</a>.)
        nil -> ""
      end

    note_html = if note, do: " " <> escape(note), else: ""

    ~s(<div style="padding:12px 16px;margin:0 0 16px;border:1px solid #d4d4d8;) <>
      ~s(background:#f4f4f5;font-family:sans-serif;font-size:14px;color:#18181b">) <>
      escape(sentence) <> link_html <> note_html <> "</div>"
  end

  defp with_banner_text(banner, text) when is_binary(text) and text != "",
    do: banner_text(banner) <> "\n\n" <> text

  defp with_banner_text(banner, _text), do: banner_text(banner)

  # The banner goes inside `<body>` when the original is a whole document.
  defp with_banner_html(banner, html, _text) when is_binary(html) and html != "" do
    case Regex.run(~r/<body\b[^>]*>/i, html, return: :index) do
      [{start, length}] ->
        {head, rest} = String.split_at(html, start + length)
        head <> banner_html(banner) <> rest

      nil ->
        banner_html(banner) <> html
    end
  end

  defp with_banner_html(banner, _html, text) when is_binary(text) and text != "",
    do: banner_html(banner) <> ~s(<pre style="white-space:pre-wrap">#{escape(text)}</pre>)

  defp with_banner_html(banner, _html, _text), do: banner_html(banner)

  defp escape(text), do: Plug.HTML.html_escape(text)

  defp base64_size(size) when is_integer(size) and size >= 0, do: div(size + 2, 3) * 4
  defp base64_size(_unknown), do: 0

  defp email_from, do: Application.get_env(:dhc, :email_from, "dev@dhc.local")

  defp forward_to,
    do: Application.get_env(:dhc, :intake_reply_forward_to) || "contact@dublinhemaclub.com"

  defp app_url, do: :dhc |> Application.fetch_env!(:app_url) |> String.trim_trailing("/")
end
