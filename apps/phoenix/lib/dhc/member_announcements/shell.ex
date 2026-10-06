defmodule Dhc.MemberAnnouncements.Shell do
  @moduledoc """
  The Member Announcement email shell (ADR 0028).

  `packages/email-templates/emails/member-announcement.tsx` is rendered by
  `pnpm --filter @dhc/email-templates render:shells` into
  `priv/email_shells/member-announcement.html` with literal `{{{SUBJECT}}}`
  and `{{{MESSAGE_HTML}}}` placeholders; the package's drift test keeps the
  committed file equal to a fresh render. This module compiles that file in
  and fills it in one pass, so neither the subject nor the body can inject a
  placeholder for the other.
  """

  alias Dhc.MemberAnnouncements.Document

  @shell_path Application.app_dir(:dhc, "priv/email_shells/member-announcement.html")
  @external_resource @shell_path
  @shell File.read!(@shell_path)
  @placeholder ~r/\{\{\{(SUBJECT|MESSAGE_HTML)\}\}\}/

  for key <- ~w(SUBJECT MESSAGE_HTML) do
    unless String.contains?(@shell, "{{{#{key}}}}") do
      raise CompileError,
        description: "#{@shell_path} is missing the {{{#{key}}}} placeholder"
    end
  end

  @doc """
  The full email HTML for a subject (plain text, escaped here) and a body
  already rendered by `Dhc.MemberAnnouncements.Document`.
  """
  @spec render(String.t(), String.t()) :: String.t()
  def render(subject, message_html) when is_binary(subject) and is_binary(message_html) do
    escaped_subject = Document.escape(subject)

    Regex.replace(@placeholder, @shell, fn
      _match, "SUBJECT" -> escaped_subject
      _match, "MESSAGE_HTML" -> message_html
    end)
  end
end
