defmodule Rail.Repo.Migrations.AddMobileTestsToQaSkipPaths do
  use Ecto.Migration

  @old ["**/*_test.exs", "**/test/**", "**/*.test.{ts,tsx,js}", "**/*.md"]
  @new ["**/*_test.exs", "**/test/**", "**/*.test.{ts,tsx,js}", "**/*Tests.swift", "**/src/androidTest/**", "**/*.md"]
  # Kotlin's `src/test/` is already under `**/test/**`.
  @mobile ["**/*Tests.swift", "**/src/androidTest/**"]

  def up do
    alter table(:projects) do
      modify :qa_skip_paths, {:array, :text}, null: false, default: @new
    end

    # A project that still skips every old default gets the mobile tests too; one that dropped a default chose its own.
    execute fn ->
      repo().query!(
        "UPDATE projects SET qa_skip_paths = qa_skip_paths || $2 WHERE qa_skip_paths @> $1 AND NOT qa_skip_paths && $2",
        [@old, @mobile]
      )
    end
  end

  def down do
    alter table(:projects) do
      modify :qa_skip_paths, {:array, :text}, null: false, default: @old
    end

    execute fn ->
      repo().query!(
        "UPDATE projects SET qa_skip_paths = array(SELECT path FROM unnest(qa_skip_paths) AS path WHERE NOT path = ANY($1))",
        [@mobile]
      )
    end
  end
end
