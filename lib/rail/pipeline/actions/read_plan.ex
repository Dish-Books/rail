defmodule Rail.Pipeline.Actions.ReadPlan do
  @moduledoc """
  Reads the implementation plan saved into a task's scratch directory, at
  `<scratch>/plans/<identifier>.md`, with the design option `save_plan` recorded beside it.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns `task`'s plan as `%{content: markdown, saved_at: time, design: %{key:, title:} | nil}`, or
  `nil` when there is none yet. A blank file is no plan. Requires `issue` to be preloaded.
  """
  def read_plan(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    dir = Path.join(scratch_path, "plans")
    path = Path.join(dir, "#{identifier}.md")

    with {:ok, content} <- File.read(path),
         false <- String.trim(content) == "",
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      %{
        content: content,
        saved_at: DateTime.from_unix!(mtime),
        design: design(Path.join(dir, "#{identifier}.design.json"))
      }
    else
      _no_plan -> nil
    end
  end

  # Rail writes this file, but a hand-edited one names no option rather than crashing the page.
  defp design(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{"key" => key, "title" => title}} when is_binary(key) and is_binary(title) <- Jason.decode(content) do
      %{key: key, title: title}
    else
      _none -> nil
    end
  end
end
