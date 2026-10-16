defmodule Dhc.BeginnersWorkshops.IntakeReplies.ReplyText do
  @moduledoc """
  The person's new words in an Intake Reply (ALE-408, ADR 0030).

  `extract/1` is the only way reply text reaches Jev, and the offline eval
  calls it too, so the eval measures exactly what production sends. It is
  pure: no storage, no logging.

  1. **Part.** The text part, or the HTML part converted to text when the text
     part is missing or blank. HTML `<blockquote>`s (Gmail, Apple Mail) are
     dropped whole.
  2. **Quoted history.** `>`-quoted lines are dropped. The first attribution
     cuts the reply there, with everything after it: "On … wrote:" (also when
     Gmail wraps it over two lines), Outlook's From/Sent/To/Subject header
     block, "-----Original Message-----", forwarded-message markers, the
     signature delimiter `-- `, and mobile footers ("Sent from my iPhone",
     "Get Outlook for …"). A separator rule right above the cut goes with it.
  3. **Redaction.** Every URL becomes `[link]` and every email address
     `[email]`, so the Intake link and addresses never leave Phoenix even when
     quoting slips past step 2. A link counts with a scheme, with `www.`, or as
     a bare host followed by a path. Names in the person's own words are not
     redacted.
  4. **Size.** At most 2,000 characters; `:empty` when nothing is left.
  """

  @limit 2_000

  @wrote ~r/\AOn\s.+\swrote:\z/i
  @markers [
    ~r/\A-{2,}\s*Original Message\s*-{2,}\z/i,
    ~r/\A-{2,}\s*Forwarded message\s*-{2,}\z/i,
    ~r/\ABegin forwarded message:\z/i,
    ~r/\A--\z/,
    ~r/\ASent from (?:my\s|Outlook\b|Mail for\b|Yahoo Mail\b|Gmail\b|Proton Mail\b)/i,
    ~r/\AGet Outlook for\s/i
  ]
  @header_from ~r/\A\*?From:\*?\s/i
  @header_sent ~r/\A\*?(?:Sent|Date):\*?\s/i
  @header_to_or_subject ~r/\A\*?(?:To|Subject):\*?\s/i
  @header_window 6
  @separator ~r/\A[_\-=]{5,}\z/

  # A scheme, `www.`, or a bare host followed by a path (how a pasted Intake
  # link looks once a client drops the scheme).
  @url ~r/\b(?:https?:\/\/|www\.|(?:[a-z0-9-]+\.)+[a-z]{2,}\/)[^\s<>"']*[^\s<>"'.,;:!?)\]]/i
  @email ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/

  @block_tags ~w(p div tr li ul ol table h1 h2 h3 h4 h5 h6 hr pre section article header footer)
  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "commat" => "@",
    "period" => ".",
    "colon" => ":",
    "sol" => "/",
    "euro" => "€",
    "pound" => "£",
    "copy" => "©",
    "rsquo" => "’",
    "lsquo" => "‘",
    "rdquo" => "”",
    "ldquo" => "“",
    "ndash" => "–",
    "mdash" => "—",
    "hellip" => "…",
    "aacute" => "á",
    "eacute" => "é",
    "iacute" => "í",
    "oacute" => "ó",
    "uacute" => "ú",
    "Aacute" => "Á",
    "Eacute" => "É",
    "Iacute" => "Í",
    "Oacute" => "Ó",
    "Uacute" => "Ú"
  }

  @type parts :: %{optional(:text) => String.t() | nil, optional(:html) => String.t() | nil}

  @doc "The person's new text, quoted history removed and links and addresses redacted."
  @spec extract(parts()) :: {:ok, String.t()} | :empty
  def extract(parts) when is_map(parts) do
    parts
    |> source()
    |> String.replace(~r/\r\n?/, "\n")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> before_history()
    |> Enum.reject(&String.starts_with?(&1, ">"))
    |> Enum.join("\n")
    |> redact()
    |> tidy()
    |> String.slice(0, @limit)
    |> String.trim()
    |> case do
      "" -> :empty
      text -> {:ok, text}
    end
  end

  defp source(parts) do
    case {Map.get(parts, :text), Map.get(parts, :html)} do
      {text, html} when is_binary(text) ->
        if String.trim(text) == "" and is_binary(html), do: html_to_text(html), else: text

      {_text, html} when is_binary(html) ->
        html_to_text(html)

      _none ->
        ""
    end
  end

  # -- Quoted history -------------------------------------------------------

  defp before_history(lines) do
    case Enum.find_index(Enum.with_index(lines), &history_starts?(&1, lines)) do
      nil -> lines
      index -> lines |> Enum.take(index) |> drop_trailing_separators()
    end
  end

  defp history_starts?({line, index}, lines) do
    Enum.any?(@markers, &Regex.match?(&1, line)) or
      wrote?(line, Enum.at(lines, index + 1)) or
      header_block?(line, index, lines)
  end

  defp wrote?(line, next) do
    Regex.match?(@wrote, line) or
      (is_binary(next) and String.starts_with?(line, "On ") and
         Regex.match?(@wrote, line <> " " <> next))
  end

  defp header_block?(line, index, lines) do
    Regex.match?(@header_from, line) and
      header_fields?(Enum.slice(lines, index + 1, @header_window))
  end

  defp header_fields?(following),
    do: has?(following, @header_sent) and has?(following, @header_to_or_subject)

  defp has?(lines, regex), do: Enum.any?(lines, &Regex.match?(regex, &1))

  defp drop_trailing_separators(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == "" or Regex.match?(@separator, &1)))
    |> Enum.reverse()
  end

  # -- Redaction and whitespace ---------------------------------------------

  defp redact(text) do
    text
    |> then(&Regex.replace(@url, &1, "[link]"))
    |> then(&Regex.replace(@email, &1, "[email]"))
  end

  defp tidy(text), do: text |> String.replace(~r/\n{3,}/, "\n\n") |> String.trim()

  # -- HTML to text ---------------------------------------------------------

  defp html_to_text(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r{<(head|style|script|title)\b[^>]*>.*?</\1\s*>}is, "")
    |> drop_blockquotes()
    |> then(&Regex.split(~r/<[^>]*>/, &1, include_captures: true))
    |> Enum.reduce({[], true}, &html_token/2)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  # `at_line_start` keeps nested and adjacent block tags from stacking blank
  # lines: a block boundary breaks the line only once, `<br>` always does.
  defp html_token("<" <> _rest = tag, {out, at_line_start}) do
    case tag_name(tag) do
      "br" -> {["\n" | out], true}
      name when name in @block_tags and at_line_start -> {out, true}
      name when name in @block_tags -> {["\n" | out], true}
      _inline -> {out, at_line_start}
    end
  end

  defp html_token(text, {out, at_line_start}) do
    case text |> String.replace(~r/\s+/, " ") |> decode_entities() do
      "" -> {out, at_line_start}
      " " when at_line_start -> {out, true}
      text -> {[text | out], false}
    end
  end

  defp tag_name(tag) do
    case Regex.run(~r{\A</?\s*([a-zA-Z0-9]+)}, tag) do
      [_tag, name] -> String.downcase(name)
      nil -> nil
    end
  end

  defp drop_blockquotes(html) do
    ~r{</?blockquote\b[^>]*>}i
    |> Regex.split(html, include_captures: true)
    |> Enum.reduce({0, []}, fn part, {depth, kept} ->
      cond do
        Regex.match?(~r{\A<blockquote}i, part) -> {depth + 1, kept}
        Regex.match?(~r{\A</blockquote}i, part) -> {max(depth - 1, 0), ["<br>" | kept]}
        depth == 0 -> {depth, [part | kept]}
        true -> {depth, kept}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp decode_entities(text) do
    Regex.replace(~r/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);/, text, fn whole, entity ->
      decode_entity(entity) || whole
    end)
  end

  defp decode_entity("#x" <> hex), do: codepoint(Integer.parse(hex, 16))
  defp decode_entity("#X" <> hex), do: codepoint(Integer.parse(hex, 16))
  defp decode_entity("#" <> decimal), do: codepoint(Integer.parse(decimal))
  defp decode_entity(name), do: Map.get(@entities, name)

  defp codepoint({code, ""}) when code in 0..0x10FFFF and code not in 0xD800..0xDFFF,
    do: <<code::utf8>>

  defp codepoint(_invalid), do: nil
end
