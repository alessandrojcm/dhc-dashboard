defmodule Dhc.Email.RichText do
  @moduledoc """
  Renders a rich-text email body — a Tiptap (ProseMirror) JSON document —
  into email-safe HTML and a plain-text alternative.

  The body is accepted as a **closed vocabulary** rather than as HTML, so no
  HTML is ever parsed or sanitised: every element in the output is written
  here, every text node is escaped, and anything outside the vocabulary is a
  validation error rather than something silently stripped.

  | Tiptap node / mark                           | Output                      |
  | -------------------------------------------- | --------------------------- |
  | `paragraph`                                  | `<p>`                       |
  | `heading` (level 2, 3)                       | `<h2>`, `<h3>`              |
  | `bulletList` / `orderedList` / `listItem`    | `<ul>` / `<ol start>` / `<li>` |
  | `blockquote`, `horizontalRule`, `hardBreak`  | `<blockquote>`, `<hr>`, `<br>` |
  | marks `bold`, `italic`, `underline`, `strike`| `<strong>`, `<em>`, `<u>`, `<s>` |
  | mark `link` (`http`, `https`, `mailto` only) | `<a href target=_blank>`    |
  | `placeholder` (only with `:placeholder`)     | its value, HTML-escaped     |

  Two callers share it:

    * Member Announcements (ADR 0028) pass `styles:` so every element carries
      its inline style, because their body is the whole email.
    * Beginners' Workshop Intake Emails (ALE-377) pass no styles — the body
      travels through one 2,000-character Resend variable and the template's
      wrapper styles it — and a `placeholder:` resolver.

  ## Options

    * `:styles` — a map of tag → CSS declarations written as a `style`
      attribute on every element. Omit for unstyled markup.
    * `:placeholder` — `fn name -> {:ok, value} | {:error, message} end`.
      Enables the inline `placeholder` node
      (`%{"type" => "placeholder", "attrs" => %{"name" => name}}`, marks
      allowed). The value is plain text and is escaped like any text node.
      Without it a placeholder node is unsupported content.
  """

  @max_depth 12
  @max_nodes 5_000

  @type rendered :: %{html: String.t(), text: String.t()}
  @type placeholder_resolver :: (String.t() -> {:ok, String.t()} | {:error, String.t()})
  @type option ::
          {:styles, %{optional(String.t()) => String.t()}}
          | {:placeholder, placeholder_resolver()}

  @doc """
  Renders a document. Returns `{:error, message}` for anything outside the
  vocabulary, a document without any visible text, or one too large to send.
  """
  @spec render(term(), [option()]) :: {:ok, rendered()} | {:error, String.t()}
  def render(doc, opts \\ [])

  def render(%{"type" => "doc"} = doc, opts) do
    ctx = %{styles: Keyword.get(opts, :styles), placeholder: Keyword.get(opts, :placeholder)}
    content = Map.get(doc, "content", [])

    with :ok <- check_size(doc),
         {:ok, blocks} <- blocks(content, 1, ctx) do
      html = Enum.map_join(blocks, & &1.html)
      text = blocks |> Enum.map(& &1.text) |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

      if String.trim(text) == "" do
        {:error, "must contain some text"}
      else
        {:ok, %{html: html, text: text}}
      end
    end
  end

  def render(_other, _opts), do: {:error, "is not a rich-text document"}

  @doc """
  The names of every `placeholder` node in a document, in order of first
  appearance. Malformed nodes are ignored here; `render/2` rejects them.
  """
  @spec placeholder_names(term()) :: [String.t()]
  def placeholder_names(doc) do
    doc |> collect_placeholders([]) |> Enum.reverse() |> Enum.uniq()
  end

  defp collect_placeholders(%{"type" => "placeholder", "attrs" => %{"name" => name}}, acc)
       when is_binary(name),
       do: [name | acc]

  defp collect_placeholders(%{"content" => content}, acc) when is_list(content),
    do: Enum.reduce(content, acc, &collect_placeholders/2)

  defp collect_placeholders(_node, acc), do: acc

  # ── Size ─────────────────────────────────────────────────────────────

  defp check_size(doc) do
    case count(doc, 0, 0) do
      :too_deep -> {:error, "is nested too deeply"}
      n when n > @max_nodes -> {:error, "is too long"}
      _n -> :ok
    end
  end

  defp count(_node, _acc, depth) when depth > @max_depth, do: :too_deep

  defp count(%{"content" => content}, acc, depth) when is_list(content) do
    Enum.reduce_while(content, acc + 1, fn child, acc ->
      case count(child, acc, depth + 1) do
        :too_deep -> {:halt, :too_deep}
        n -> {:cont, n}
      end
    end)
  end

  defp count(_node, acc, _depth), do: acc + 1

  # ── Blocks ───────────────────────────────────────────────────────────

  defp blocks(content, depth, ctx) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case block(node, depth, ctx) do
        {:ok, rendered} -> {:cont, {:ok, [rendered | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp blocks(_content, _depth, _ctx), do: {:error, "has malformed content"}

  defp block(%{"type" => "paragraph"} = node, _depth, ctx) do
    with {:ok, inline} <- inline(Map.get(node, "content", []), ctx) do
      html = if inline.html == "", do: "<br>", else: inline.html
      {:ok, %{html: element("p", html, ctx), text: inline.text}}
    end
  end

  defp block(%{"type" => "heading", "attrs" => %{"level" => level}} = node, _depth, ctx)
       when level in [2, 3] do
    with {:ok, inline} <- inline(Map.get(node, "content", []), ctx) do
      {:ok, %{html: element("h#{level}", inline.html, ctx), text: inline.text}}
    end
  end

  defp block(%{"type" => "heading"}, _depth, _ctx),
    do: {:error, "only supports headings 2 and 3"}

  defp block(%{"type" => "bulletList"} = node, depth, ctx) do
    with {:ok, items} <- list_items(node, depth, ctx) do
      {:ok,
       %{
         html: element("ul", Enum.map_join(items, & &1.html), ctx),
         text: Enum.map_join(items, "\n", &("• " <> &1.text))
       }}
    end
  end

  defp block(%{"type" => "orderedList"} = node, depth, ctx) do
    start =
      case node do
        %{"attrs" => %{"start" => start}} when is_integer(start) and start >= 0 -> start
        _ -> 1
      end

    with {:ok, items} <- list_items(node, depth, ctx) do
      start_attr = if start == 1, do: "", else: ~s( start="#{start}")

      {:ok,
       %{
         html: element("ol", Enum.map_join(items, & &1.html), ctx, start_attr),
         text:
           items
           |> Enum.with_index(start)
           |> Enum.map_join("\n", fn {item, n} -> "#{n}. " <> item.text end)
       }}
    end
  end

  defp block(%{"type" => "blockquote"} = node, depth, ctx) do
    with {:ok, children} <- blocks(Map.get(node, "content", []), depth + 1, ctx) do
      text =
        children
        |> Enum.map_join("\n", & &1.text)
        |> String.split("\n")
        |> Enum.map_join("\n", &("> " <> &1))

      {:ok, %{html: element("blockquote", Enum.map_join(children, & &1.html), ctx), text: text}}
    end
  end

  defp block(%{"type" => "horizontalRule"}, _depth, ctx),
    do: {:ok, %{html: "<hr#{style_attr("hr", ctx)}>", text: "———"}}

  defp block(%{"type" => type}, _depth, _ctx) when is_binary(type),
    do: {:error, "contains unsupported content (#{type})"}

  defp block(_node, _depth, _ctx), do: {:error, "has malformed content"}

  defp list_items(%{"content" => [_ | _] = items}, depth, ctx) do
    items
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "listItem"} = item, {:ok, acc} ->
        case list_item(item, depth, ctx) do
          {:ok, rendered} -> {:cont, {:ok, [rendered | acc]}}
          error -> {:halt, error}
        end

      _other, _acc ->
        {:halt, {:error, "has malformed list content"}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp list_items(_node, _depth, _ctx), do: {:error, "has an empty list"}

  # A styled paragraph inside a list item drops its own bottom margin; the
  # item spacing comes from `li`. Unstyled markup leaves that to the
  # template's stylesheet.
  defp list_item(item, depth, ctx) do
    with {:ok, children} <- blocks(Map.get(item, "content", []), depth + 1, ctx) do
      html = Enum.map_join(children, &unmargin_paragraph(&1.html, ctx))

      {:ok, %{html: element("li", html, ctx), text: Enum.map_join(children, "\n  ", & &1.text)}}
    end
  end

  defp unmargin_paragraph(html, %{styles: nil}), do: html

  defp unmargin_paragraph(html, ctx) do
    String.replace(
      html,
      ~s(<p style="#{style("p", ctx)}">),
      ~s(<p style="#{style("p", ctx)};margin:0">)
    )
  end

  # ── Inline ───────────────────────────────────────────────────────────

  defp inline(content, ctx) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, {[], []}}, fn node, {:ok, {html, text}} ->
      case inline_node(node, ctx) do
        {:ok, {h, t}} -> {:cont, {:ok, {[h | html], [t | text]}}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, {html, text}} ->
        {:ok,
         %{
           html: html |> Enum.reverse() |> IO.iodata_to_binary(),
           text: text |> Enum.reverse() |> IO.iodata_to_binary()
         }}

      error ->
        error
    end
  end

  defp inline(_content, _ctx), do: {:error, "has malformed content"}

  defp inline_node(%{"type" => "text", "text" => text} = node, ctx) when is_binary(text) do
    marked(text, Map.get(node, "marks", []), ctx)
  end

  defp inline_node(%{"type" => "hardBreak"}, _ctx), do: {:ok, {"<br>", "\n"}}

  defp inline_node(%{"type" => "placeholder", "attrs" => %{"name" => name}} = node, ctx)
       when is_binary(name) and is_function(ctx.placeholder, 1) do
    case ctx.placeholder.(name) do
      {:ok, value} when is_binary(value) -> marked(value, Map.get(node, "marks", []), ctx)
      {:error, message} -> {:error, message}
    end
  end

  defp inline_node(%{"type" => "placeholder"}, %{placeholder: resolver})
       when is_function(resolver, 1),
       do: {:error, "has a malformed placeholder"}

  defp inline_node(%{"type" => type}, _ctx) when is_binary(type),
    do: {:error, "contains unsupported content (#{type})"}

  defp inline_node(_node, _ctx), do: {:error, "has malformed content"}

  defp marked(text, marks, ctx) do
    with {:ok, marks} <- marks(marks) do
      html =
        Enum.reduce(marks, escape(text), fn
          {:link, href}, acc ->
            ~s(<a href="#{escape(href)}" target="_blank" rel="noopener noreferrer"#{style_attr("a", ctx)}>#{acc}</a>)

          tag, acc ->
            element(tag, acc, ctx)
        end)

      text_out =
        case Enum.find(marks, &match?({:link, _}, &1)) do
          {:link, href} when href != text -> "#{text} (#{href})"
          _ -> text
        end

      {:ok, {html, text_out}}
    end
  end

  @mark_tags %{"bold" => "strong", "italic" => "em", "underline" => "u", "strike" => "s"}

  defp marks(marks) when is_list(marks) do
    Enum.reduce_while(marks, {:ok, []}, fn
      %{"type" => "link", "attrs" => %{"href" => href}}, {:ok, acc} when is_binary(href) ->
        if allowed_href?(href),
          do: {:cont, {:ok, acc ++ [{:link, href}]}},
          else: {:halt, {:error, "links must start with https://, http:// or mailto:"}}

      %{"type" => type}, {:ok, acc} when is_map_key(@mark_tags, type) ->
        {:cont, {:ok, acc ++ [Map.fetch!(@mark_tags, type)]}}

      %{"type" => type}, _acc when is_binary(type) ->
        {:halt, {:error, "contains unsupported formatting (#{type})"}}

      _mark, _acc ->
        {:halt, {:error, "has malformed formatting"}}
    end)
  end

  defp marks(_marks), do: {:error, "has malformed formatting"}

  defp allowed_href?(href) do
    case URI.new(href) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      {:ok, %URI{scheme: "mailto", path: path}} ->
        is_binary(path) and path != ""

      _ ->
        false
    end
  end

  # ── HTML helpers ─────────────────────────────────────────────────────

  defp element(tag, inner, ctx, extra_attrs \\ "") do
    ~s(<#{tag}#{extra_attrs}#{style_attr(tag, ctx)}>#{inner}</#{tag}>)
  end

  defp style_attr(_tag, %{styles: nil}), do: ""
  defp style_attr(tag, ctx), do: ~s( style="#{style(tag, ctx)}")

  # Styles contain quoted font names, so they are escaped for the attribute.
  defp style(tag, %{styles: styles}), do: escape(Map.fetch!(styles, tag))

  @doc "HTML-escapes text for element content and double-quoted attributes."
  @spec escape(String.t()) :: String.t()
  def escape(text) when is_binary(text) do
    for <<char <- text>>, into: "" do
      case char do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?> -> "&gt;"
        ?" -> "&quot;"
        ?' -> "&#39;"
        _ -> <<char>>
      end
    end
  end
end
