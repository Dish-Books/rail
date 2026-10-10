defmodule Rail.Repo.Migrations.MarkSplitChildrenBuildingTheScreen do
  use Ecto.Migration

  # Approval gave a split saved before the mark the design for every child, so each of its children is
  # marked as building the screen. The file keeps its mtime, which `read_split/1` reads as when it was saved.
  def up do
    %{rows: rows} =
      repo().query!("""
      SELECT tasks.scratch_path, issues.identifier
      FROM tasks JOIN issues ON issues.id = tasks.issue_id
      WHERE tasks.cleaned_up_at IS NULL
      """)

    for [scratch_path, identifier] <- rows do
      mark(Path.join([scratch_path, "splits", "#{identifier}.json"]))
    end
  end

  def down, do: :ok

  defp mark(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{"children" => children} = split} when is_list(children) <- Jason.decode(content),
         true <- Enum.any?(children, &(not Map.has_key?(&1, "builds_screen"))),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      children = Enum.map(children, &Map.put_new(&1, "builds_screen", true))
      temporary = path <> ".rewrite"
      File.write!(temporary, Jason.encode!(%{split | "children" => children}, pretty: true))
      File.rename!(temporary, path)
      File.touch!(path, mtime)
    end
  end
end
