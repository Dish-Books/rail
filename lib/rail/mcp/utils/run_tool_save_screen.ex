defmodule Rail.Mcp.Utils.RunToolSaveScreen do
  @moduledoc """
  Photographs one screen state the lead named and saves it as that state's image for HEAD's commit, so the
  Screens item can set each round's picture beside the last. A worktree with uncommitted changes is
  refused, since its picture would belong to no commit.
  """

  import Rail.Mcp.Utils.NamedBrowser

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @key ~r/\A[a-z0-9][a-z0-9-]{0,59}\z/

  @doc """
  Captures the browser `arguments["browser"]` names on `task` as the screen state `arguments["key"]`,
  labeled `arguments["label"]`, and says which commit it was saved for.
  """
  def run_tool_save_screen(%Task{} = task, %{"key" => key, "label" => label} = arguments, opts)
      when is_binary(key) and is_binary(label) do
    label = String.trim(label)

    cond do
      not (key =~ @key) ->
        {:refused,
         "Refused, nothing saved. `key` is the state's name, lowercase letters, digits and dashes, up to 60, " <>
           "the same every round."}

      label == "" or String.length(label) > 120 ->
        {:refused, "Refused, nothing saved. `label` says what the state shows, in 120 characters or less."}

      not Task.worktree_present?(task) or Git.worktree_dirty?(task.worktree_path) ->
        {:refused,
         "Refused, nothing saved. The worktree has uncommitted changes, so the picture would belong to no " <>
           "commit. Take it once they are committed."}

      true ->
        save(task, key, label, arguments, opts)
    end
  end

  def run_tool_save_screen(%Task{}, _arguments, _opts) do
    {:refused, "Refused, nothing saved. save_screen needs the state's `key` and a `label` saying what it shows."}
  end

  defp save(%Task{} = task, key, label, arguments, opts) do
    with {:ok, browser, session} <- named_browser(task, arguments, opts),
         {:ok, file} <- Tools.capture_browser_evidence(session, task, label, key),
         {:ok, %{commit: commit}} <- Pipeline.save_screen(task, %{key: key, label: label, file: file, browser: browser}) do
      {:ok,
       "Saved as #{file}, the image of #{key} on #{String.slice(commit || "no commit", 0, 7)}. Give that path " <>
         "to the lead to cite in a finding that turns on this screen."}
    end
  end
end
