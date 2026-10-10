defmodule Rail.Pipeline.Actions.SaveSplit do
  @moduledoc """
  Checks a split the architect saved and writes it where `read_split/1` reads it. Only a complete
  split is ever written, so a refused save leaves the last good one, and no children removes it.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Split
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Saves `attrs["children"]` as `task`'s split, in order. Returns `{:ok, split}` as `read_split/1`
  reads it, `{:ok, nil}` once an empty list has removed it, or `{:error, changeset}`.
  """
  def save_split(%Task{} = task, attrs) when is_map(attrs) do
    %Task{issue: %Issue{identifier: identifier}} = task = Repo.preload(task, :issue)
    path = Path.join([task.scratch_path, "splits", "#{identifier}.json"])

    case attrs |> Map.new(fn {key, value} -> {to_string(key), value} end) |> Map.get("children") do
      [] ->
        File.rm(path)
        Pipeline.broadcast_output_saved(task)
        {:ok, nil}

      _children ->
        with {:ok, %Split{children: children}} <- %Split{} |> Split.changeset(attrs) |> apply_action(:insert) do
          children = Enum.map(children, &Map.take(&1, [:title, :ticket, :estimate, :plan, :builds_on, :builds_screen]))
          write_scratch_file(path, Jason.encode!(%{children: children}, pretty: true))
          Pipeline.broadcast_output_saved(task)

          {:ok, Pipeline.read_split(task)}
        end
    end
  end
end
