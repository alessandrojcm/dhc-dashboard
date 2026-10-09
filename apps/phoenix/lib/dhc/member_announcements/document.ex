defmodule Dhc.MemberAnnouncements.Document do
  @moduledoc """
  Renders a Member Announcement body — a Tiptap (ProseMirror) JSON document —
  into email-safe HTML and a plain-text alternative (ADR 0028).

  The closed vocabulary itself lives in `Dhc.Email.RichText`, shared with the
  Beginners' Workshop Intake Emails. A Member Announcement body is the whole
  email, so every element carries its inline style from the email package's
  `MESSAGE_STYLES` (`priv/email_shells/member-announcement.styles.json`),
  because email clients ignore most `<style>` blocks.
  """

  alias Dhc.Email.RichText

  @styles_path Application.app_dir(:dhc, "priv/email_shells/member-announcement.styles.json")
  @external_resource @styles_path
  @styles @styles_path |> File.read!() |> Jason.decode!()

  @type rendered :: RichText.rendered()

  @doc """
  Renders a document. Returns `{:error, message}` for anything outside the
  vocabulary, a document without any visible text, or one too large to send.
  """
  @spec render(term()) :: {:ok, rendered()} | {:error, String.t()}
  def render(doc), do: RichText.render(doc, styles: @styles)

  @doc "HTML-escapes text for element content and double-quoted attributes."
  @spec escape(String.t()) :: String.t()
  defdelegate escape(text), to: RichText
end
