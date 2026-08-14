defmodule Dhc.Auth.ExternalIdentity do
  @moduledoc """
  An immutable provider subject linked to one Authentication Principal.

  Provider profile attributes are retained only as metadata. They never update
  the Principal's authoritative login email and never change an existing link.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "external_identities" do
    field :provider, :string
    field :provider_subject, :string
    field :metadata, :map, default: %{}
    field :sign_in_disabled_at, :utc_datetime_usec

    belongs_to :principal, Dhc.Auth.Principal

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def create_changeset(identity, principal, attrs) do
    identity
    |> cast(attrs, [:provider, :provider_subject, :metadata])
    |> put_assoc(:principal, principal)
    |> validate_required([:provider, :provider_subject])
    |> unique_constraint([:provider, :provider_subject],
      name: "unique_external_identities_provider_subject"
    )
    |> unique_constraint([:principal_id, :provider],
      name: "unique_external_identities_principal_provider"
    )
  end
end
