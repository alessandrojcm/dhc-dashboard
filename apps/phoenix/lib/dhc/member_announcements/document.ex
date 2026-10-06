defmodule Dhc.MemberAnnouncements.Document do
  @moduledoc """
  Renders a Member Announcement body — a Tiptap (ProseMirror) JSON document —
  into email-safe HTML and a plain-text alternative (ADR 0028).

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

  Inline styles come from the email package's `MESSAGE_STYLES`
  (`priv/email_shells/member-announcement.styles.json`), because email
  clients ignore most `<style>` blocks.
  """

  @styles_path Application.app_dir(:dhc, "priv/email_shells/member-announcement.styles.json")
  @external_resource @styles_path
  @styles @styles_path |> File.read!() |> Jason.decode!()

  @max_depth 12
  @max_nodes 5_000

  @type rendered :: %{html: String.t(), text: String.t()}

  @doc """
  Renders a document. Returns `{:error, message}` for anything outside the
  vocabulary, a document without any visible text, or one too large to send.
  """
  @spec render(term()) :: {:ok, rendered()} | {:error, String.t()}
  def render(%{"type" => "doc"} = doc) do
    content = Map.get(doc, "content", [])

    with :ok <- check_size(doc),
         {:ok, blocks} <- blocks(content, 1) do
      html = Enum.map_join(blocks, & &1.html)
      text = blocks |> Enum.map(& &1.text) |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

      if String.trim(text) == "" do
        {:error, "must contain some text"}
      else
        {:ok, %{html: html, text: text}}
      end
    end
  end

  def render(_other), do: {:error, "is not a rich-text document"}

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

  defp blocks(content, depth) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case block(node, depth) do
        {:ok, rendered} -> {:cont, {:ok, [rendered | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp blocks(_content, _depth), do: {:error, "has malformed content"}

  defp block(%{"type" => "paragraph"} = node, _depth) do
    with {:ok, inline} <- inline(Map.get(node, "content", [])) do
      html = if inline.html == "", do: "<br>", else: inline.html
      {:ok, %{html: element("p", html), text: inline.text}}
    end
  end

  defp block(%{"type" => "heading", "attrs" => %{"level" => level}} = node, _depth)
       when level in [2, 3] do
    with {:ok, inline} <- inline(Map.get(node, "content", [])) do
      {:ok, %{html: element("h#{level}", inline.html), text: inline.text}}
    end
  end

  defp block(%{"type" => "heading"}, _depth), do: {:error, "only supports headings 2 and 3"}

  defp block(%{"type" => "bulletList"} = node, depth) do
    with {:ok, items} <- list_items(node, depth) do
      {:ok,
       %{
         html: element("ul", Enum.map_join(items, & &1.html)),
         text: Enum.map_join(items, "\n", &("• " <> &1.text))
       }}
    end
  end

  defp block(%{"type" => "orderedList"} = node, depth) do
    start =
      case node do
        %{"attrs" => %{"start" => start}} when is_integer(start) and start >= 0 -> start
        _ -> 1
      end

    with {:ok, items} <- list_items(node, depth) do
      start_attr = if start == 1, do: "", else: ~s( start="#{start}")

      {:ok,
       %{
         html: element("ol", Enum.map_join(items, & &1.html), start_attr),
         text:
           items
           |> Enum.with_index(start)
           |> Enum.map_join("\n", fn {item, n} -> "#{n}. " <> item.text end)
       }}
    end
  end

  defp block(%{"type" => "blockquote"} = node, depth) do
    with {:ok, children} <- blocks(Map.get(node, "content", []), depth + 1) do
      text =
        children
        |> Enum.map_join("\n", & &1.text)
        |> String.split("\n")
        |> Enum.map_join("\n", &("> " <> &1))

      {:ok, %{html: element("blockquote", Enum.map_join(children, & &1.html)), text: text}}
    end
  end

  defp block(%{"type" => "horizontalRule"}, _depth),
    do: {:ok, %{html: ~s(<hr style="#{style("hr")}">), text: "———"}}

  defp block(%{"type" => type}, _depth) when is_binary(type),
    do: {:error, "contains unsupported content (#{type})"}

  defp block(_node, _depth), do: {:error, "has malformed content"}

  defp list_items(%{"content" => [_ | _] = items}, depth) do
    items
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "listItem"} = item, {:ok, acc} ->
        case list_item(item, depth) do
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

  defp list_items(_node, _depth), do: {:error, "has an empty list"}

  # A paragraph inside a list item drops its own bottom margin; the item
  # spacing comes from `li`.
  defp list_item(item, depth) do
    with {:ok, children} <- blocks(Map.get(item, "content", []), depth + 1) do
      html =
        Enum.map_join(children, fn child ->
          String.replace(
            child.html,
            ~s(<p style="#{style("p")}">),
            ~s(<p style="#{style("p")};margin:0">)
          )
        end)

      {:ok, %{html: element("li", html), text: Enum.map_join(children, "\n  ", & &1.text)}}
    end
  end

  # ── Inline ───────────────────────────────────────────────────────────

  defp inline(content) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, {[], []}}, fn node, {:ok, {html, text}} ->
      case inline_node(node) do
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

  defp inline(_content), do: {:error, "has malformed content"}

  defp inline_node(%{"type" => "text", "text" => text} = node) when is_binary(text) do
    marks = Map.get(node, "marks", [])

    with {:ok, marks} <- marks(marks) do
      escaped = escape(text)

      html =
        Enum.reduce(marks, escaped, fn
          {:link, href}, acc ->
            ~s(<a href="#{escape(href)}" target="_blank" rel="noopener noreferrer" style="#{style("a")}">#{acc}</a>)

          tag, acc ->
            element(tag, acc)
        end)

      text_out =
        case Enum.find(marks, &match?({:link, _}, &1)) do
          {:link, href} when href != text -> "#{text} (#{href})"
          _ -> text
        end

      {:ok, {html, text_out}}
    end
  end

  defp inline_node(%{"type" => "hardBreak"}), do: {:ok, {"<br>", "\n"}}

  defp inline_node(%{"type" => type}) when is_binary(type),
    do: {:error, "contains unsupported content (#{type})"}

  defp inline_node(_node), do: {:error, "has malformed content"}

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

  defp element(tag, inner, extra_attrs \\ "") do
    ~s(<#{tag}#{extra_attrs} style="#{style(tag)}">#{inner}</#{tag}>)
  end

  # Styles contain quoted font names, so they are escaped for the attribute.
  defp style(tag), do: escape(Map.fetch!(@styles, tag))

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
