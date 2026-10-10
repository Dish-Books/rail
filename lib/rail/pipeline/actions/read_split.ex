defmodule Rail.Pipeline.Actions.ReadSplit do
  @moduledoc """
  Reads the split saved at `<scratch>/splits/<identifier>.json`. Only `save_split` writes it, and
  only complete splits, so the file is read as it stands.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns `task`'s split as `%{children:, saved_at:}`, each child numbered from 1, or `nil` when there
  is none. Requires `issue` to be preloaded.
  """
  def read_split(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    path = Path.join([scratch_path, "splits", "#{identifier}.json"])

    case File.read(path) do
      {:ok, content} ->
        %{"children" => children} = Jason.decode!(content)
        {:ok, %File.Stat{mtime: mtime}} = File.stat(path, time: :posix)

        children =
          children
          |> Enum.with_index(1)
          |> Enum.map(fn {child, number} ->
            %{
              number: number,
              title: Map.fetch!(child, "title"),
              ticket: Map.fetch!(child, "ticket"),
              estimate: Map.fetch!(child, "estimate"),
              plan: Map.fetch!(child, "plan"),
              builds_on: Map.fetch!(child, "builds_on"),
              builds_screen: Map.fetch!(child, "builds_screen")
            }
          end)

        %{children: children, saved_at: DateTime.from_unix!(mtime)}

      {:error, :enoent} ->
        nil
    end
  end
end
