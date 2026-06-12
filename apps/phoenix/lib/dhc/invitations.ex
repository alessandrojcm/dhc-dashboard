defmodule Dhc.Invitations do
  @moduledoc """
  Invitation context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.Email.Worker, as: EmailWorker
  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.Repository
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @invite_email_template "inviteMember"

  @doc """
  Re-enqueues invite-member emails for existing invitations.
  """
  @spec resend_invitation_emails([String.t()]) ::
          {:ok, %{succeeded: non_neg_integer(), failed: non_neg_integer()}}
  def resend_invitation_emails(emails) when is_list(emails) and length(emails) > 0 do
    invite_data = list_invitation_resend_data(emails)

    succeeded =
      invite_data
      |> Enum.map(&enqueue_invitation_email/1)
      |> Enum.count(&match?(:ok, &1))

    found_emails = Enum.map(invite_data, & &1.email)

    if found_emails != [] do
      expire_for_resend(found_emails)
    end

    {:ok, %{succeeded: succeeded, failed: length(emails) - succeeded}}
  end

  def resend_invitation_emails(_emails), do: {:ok, %{succeeded: 0, failed: 0}}

  defp list_invitation_resend_data(emails) do
    from(i in Invitation,
      left_join: up in UserProfile,
      on: up.supabase_user_id == i.user_id,
      where: i.email in ^emails,
      select: %{
        id: i.id,
        email: i.email,
        first_name: up.first_name,
        last_name: up.last_name,
        date_of_birth: up.date_of_birth
      }
    )
    |> Repo.all()
  end

  defp enqueue_invitation_email(invitation) do
    args = %{
      "email" => invitation.email,
      "transactional_id" => @invite_email_template,
      "data_variables" => %{
        "firstName" => invitation.first_name || "",
        "lastName" => invitation.last_name || "",
        "invitationLink" => invitation_link(invitation)
      }
    }

    case Oban.insert(EmailWorker.new(args)) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp expire_for_resend(emails) do
    from(i in Invitation, where: i.email in ^emails)
    |> Repo.update_all(
      set: [status: "pending", expires_at: DateTime.add(DateTime.utc_now(), 1, :day)]
    )
  end

  defp invitation_link(invitation) do
    app_url = Application.fetch_env!(:dhc, :app_url)

    app_url
    |> URI.merge("/members/signup/#{invitation.id}")
    |> Map.put(
      :query,
      URI.encode_query(%{
        "dateOfBirth" => Repository.date_string(invitation.date_of_birth),
        "email" => invitation.email
      })
    )
    |> URI.to_string()
  end
end
