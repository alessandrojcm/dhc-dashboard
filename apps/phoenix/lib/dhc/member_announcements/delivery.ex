defmodule Dhc.MemberAnnouncements.Delivery do
  @moduledoc """
  Sends one Member Announcement through the Swoosh transport seam
  (ADRs 0021 and 0028).

  Recipients are **BCC'd**: the frozen addresses are split into groups of
  49 (Resend accepts at most 50 recipients per email, and the visible `To`
  — the club's own address — is one of them), each group is one email, and
  the emails go to Resend's batch endpoint in requests of at most 100. A club
  of a few hundred members is therefore one `POST /emails/batch`.

  Every batch request carries the idempotency key
  `member-announcement:<id>:<batch>`. The payload is frozen on the row, so
  a retried job sends byte-identical requests and Resend returns the
  original result instead of sending again (keys are honoured for 24 hours).

  Adapters without a batch implementation (Mailpit in dev) receive the same
  emails one by one.
  """

  alias Dhc.Email.Mailer
  alias Dhc.MemberAnnouncements.Announcement
  alias Swoosh.Email

  @bcc_per_email 49
  @emails_per_batch 100

  @doc "The emails for an announcement, grouped into batch requests."
  @spec batches(Announcement.t()) :: [[Email.t()]]
  def batches(%Announcement{} = announcement) do
    announcement.recipient_emails
    |> Enum.chunk_every(@bcc_per_email)
    |> Enum.map(&email(announcement, &1))
    |> Enum.chunk_every(@emails_per_batch)
    |> Enum.with_index()
    |> Enum.map(fn {[first | rest], index} ->
      key = "member-announcement:#{announcement.id}:#{index}"
      [Email.put_provider_option(first, :idempotency_key, key) | rest]
    end)
  end

  @doc """
  Delivers every batch. Stops at the first failed request and returns the
  adapter's error; earlier batches are safe to resend under their keys.
  """
  @spec deliver(Announcement.t()) :: :ok | {:error, term()}
  def deliver(%Announcement{} = announcement) do
    announcement
    |> batches()
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case deliver_batch(batch) do
        {:ok, _receipts} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp email(announcement, bcc) do
    Email.new()
    |> Email.from(email_from())
    |> Email.to(email_from())
    |> Email.bcc(bcc)
    |> Email.reply_to(email_reply_to())
    |> Email.subject(announcement.subject)
    |> Email.html_body(announcement.email_html)
    |> Email.text_body(announcement.email_text)
  end

  defp deliver_batch(emails) do
    if batch_supported?(), do: Mailer.deliver_many(emails), else: deliver_each(emails)
  end

  defp deliver_each(emails) do
    Enum.reduce_while(emails, {:ok, []}, fn email, {:ok, receipts} ->
      case Mailer.deliver(email) do
        {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp batch_supported? do
    adapter = :dhc |> Application.get_env(Mailer, []) |> Keyword.get(:adapter)

    is_atom(adapter) and Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :deliver_many, 2)
  end

  defp email_from, do: Application.get_env(:dhc, :email_from, "dev@dhc.local")

  defp email_reply_to,
    do: Application.get_env(:dhc, :email_reply_to, "contact@dublinhemaclub.com")
end
