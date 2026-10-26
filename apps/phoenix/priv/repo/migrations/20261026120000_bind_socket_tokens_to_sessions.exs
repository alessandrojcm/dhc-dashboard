defmodule Dhc.Repo.Migrations.BindSocketTokensToSessions do
  use Ecto.Migration

  # Security-audit run-1 lead 4: a socket credential used to outlive the
  # logout that deleted the session it was exchanged from. Socket tokens are
  # now bound to the originating `principal_tokens` row (context "session");
  # deleting the session deletes its socket tokens (FK cascade), and the
  # socket verifiers require the bound session row to still exist.
  #
  # Existing socket-token rows keep a NULL binding and stop verifying: the
  # socket-token validity window is 60 s, so nothing live outlives this
  # deploy.
  def change do
    alter table(:principal_tokens) do
      add :session_token_id,
          references(:principal_tokens, type: :binary_id, on_delete: :delete_all)
    end

    create index(:principal_tokens, [:session_token_id])
  end
end
