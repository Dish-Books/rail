defmodule Rail.Repo.Migrations.AddQaSkipPathsToProjects do
  use Ecto.Migration

  # A later round that changed only these files gets no QA or demo, as nothing a person sees can have moved.
  def change do
    alter table(:projects) do
      add :qa_skip_paths, {:array, :text},
        null: false,
        default: ["**/*_test.exs", "**/test/**", "**/*.test.{ts,tsx,js}", "**/*.md"]
    end
  end
end
