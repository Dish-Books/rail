defmodule Rail.Repo.Migrations.CreatePreviews do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :preview_enabled, :boolean, default: false, null: false
      add :preview_url_template, :text
      add :preview_login_path, :text
      add :preview_database, :text
      add :preview_access_client_id, :binary
      add :preview_access_client_secret, :binary
    end

    create table(:previews) do
      add :task_id, references(:tasks, type: :text, on_delete: :delete_all), null: false
      add :url, :text, null: false
      add :status, :text, null: false
      add :live_sha, :text
      add :checked_at, :utc_datetime_usec
      add :live_at, :utc_datetime_usec
      add :seeded_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:previews, [:task_id])

    # A comment on an element of the running app, beside those on a shot QA took.
    alter table(:screen_comments) do
      add :source, :text, default: "shot", null: false
      add :selector, :text
      add :element_text, :text
      add :element_tag, :text
      add :picture_path, :text
    end
  end
end
