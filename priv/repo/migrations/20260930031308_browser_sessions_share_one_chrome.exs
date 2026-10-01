defmodule Rail.Repo.Migrations.BrowserSessionsShareOneChrome do
  @moduledoc false
  use Ecto.Migration

  # A session is a browser context and a tab in the one shared Chrome rather than
  # a Chrome of its own, so there is no process or profile per row to reap - and
  # the context is what a task's tab is found again by after Rail restarts.
  def change do
    alter table(:browser_sessions) do
      add :browser_context_id, :text
      remove :os_pid, :integer
      remove :profile_path, :text
    end
  end
end
