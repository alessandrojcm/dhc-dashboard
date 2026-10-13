defmodule Dhc.BeginnersWorkshops.IntakeReplies do
  @moduledoc """
  Issues and resolves the per-email Reply-To credential for Intake Emails
  (ALE-407). Only token hashes are persisted; the address itself is carried
  to the email worker in a sealed Oban argument.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.IntakeReplyAddress
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  @token_bytes 20
  @domain_regex ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/
  @local_part_regex ~r/\A[a-zA-Z0-9]+\z/

  @doc false
  @spec reply_to(WaitlistEntry.t(), Ecto.UUID.t() | nil, String.t()) ::
          {:ok, String.t() | nil} | {:error, Ecto.Changeset.t()}
  def reply_to(%WaitlistEntry{id: waitlist_id}, intake_id, email_type)
      when is_binary(email_type) do
    case reply_domain() do
      nil ->
        {:ok, nil}

      domain ->
        token = random_token()

        binding = %IntakeReplyAddress{
          waitlist_id: waitlist_id,
          intake_id: intake_id,
          email_type: email_type,
          token_hash: token_hash(token)
        }

        case binding |> IntakeReplyAddress.changeset() |> Repo.insert() do
          {:ok, _binding} -> {:ok, "#{token}@#{domain}"}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc "Resolves a Reply-To address without accepting addresses on other domains."
  @spec resolve(term()) :: {:ok, IntakeReplyAddress.t()} | :unknown
  def resolve(address) when is_binary(address) do
    with domain when is_binary(domain) <- reply_domain(),
         [local_part, supplied_domain] <- String.split(address, "@"),
         true <- Regex.match?(@local_part_regex, local_part),
         true <- String.downcase(supplied_domain) == domain do
      hash = local_part |> String.downcase() |> token_hash()

      case Repo.one(
             from(binding in IntakeReplyAddress,
               where: binding.token_hash == ^hash,
               preload: [:waitlist_entry, :intake]
             )
           ) do
        %IntakeReplyAddress{} = binding -> {:ok, binding}
        nil -> :unknown
      end
    else
      _not_a_reply_address -> :unknown
    end
  end

  def resolve(_address), do: :unknown

  @doc false
  @spec delete_for_person(Ecto.UUID.t()) :: non_neg_integer()
  def delete_for_person(waitlist_id) when is_binary(waitlist_id) do
    {deleted, _rows} =
      Repo.delete_all(
        from(binding in IntakeReplyAddress, where: binding.waitlist_id == ^waitlist_id)
      )

    deleted
  end

  defp random_token do
    :crypto.strong_rand_bytes(@token_bytes)
    |> Base.encode32(case: :lower, padding: false)
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token)

  defp reply_domain do
    case Application.get_env(:dhc, :intake_reply_domain) do
      domain when is_binary(domain) ->
        normalized = domain |> String.trim() |> String.downcase()
        if Regex.match?(@domain_regex, normalized), do: normalized

      _unset_or_invalid ->
        nil
    end
  end
end
