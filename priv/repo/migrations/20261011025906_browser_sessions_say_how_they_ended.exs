defmodule Rail.Repo.Migrations.BrowserSessionsSayHowTheyEnded do
  @moduledoc false
  use Ecto.Migration

  # A browser Chrome lost under a running pass is told apart from one Rail closed, so the agent that
  # asks for it again is told its tab and sign-in are gone rather than handed a blank one.
  def change do
    alter table(:browser_sessions) do
      add :ended_reason, :text
    end
  end
end
