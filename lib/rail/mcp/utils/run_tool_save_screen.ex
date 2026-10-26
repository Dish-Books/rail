defmodule Rail.Mcp.Utils.RunToolSaveScreen do
  @moduledoc """
  Photographs one screen state QA named and saves it as that state's image for HEAD's commit, which
  replaces the state's earlier picture. A worktree with uncommitted changes is refused, since its picture
  would belong to no commit, and so is a picture all one color, which leaves the earlier one in place.
  """

  import Rail.Mcp.Utils.NamedBrowser

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @key ~r/\A[a-z0-9][a-z0-9-]{0,59}\z/

  # Rail clears its width after the picture, which also ends a width QA's script set.
  @unsized " The tab is back at its own width now, so a script holding a resize has to set it again."

  @doc """
  Captures the browser `arguments["browser"]` names on `task` as the screen state `arguments["key"]`,
  labeled `arguments["label"]` and laid out `arguments["width"]` wide when given, and says which commit it
  was saved for alongside the picture.
  """
  def run_tool_save_screen(%Task{} = task, %{"key" => key, "label" => label} = arguments, opts)
      when is_binary(key) and is_binary(label) do
    label = String.trim(label)
    width = arguments["width"]

    cond do
      not (key =~ @key) ->
        {:refused,
         "Refused, nothing saved. `key` is the state's name, lowercase letters, digits and dashes, up to 60, " <>
           "the same every round."}

      label == "" or String.length(label) > 120 ->
        {:refused, "Refused, nothing saved. `label` says what the state shows, in 120 characters or less."}

      not width?(width) ->
        {:refused,
         "Refused, nothing saved. `width` is the width to lay the page out at, a whole number from 320 to 1920."}

      not Task.worktree_present?(task) or Git.worktree_dirty?(task.worktree_path) ->
        {:refused,
         "Refused, nothing saved. The worktree has uncommitted changes, so the picture would belong to no " <>
           "commit. Take it once they are committed."}

      true ->
        save(task, key, label, width, arguments, opts)
    end
  end

  def run_tool_save_screen(%Task{}, _arguments, _opts) do
    {:refused, "Refused, nothing saved. save_screen needs the state's `key` and a `label` saying what it shows."}
  end

  defp save(%Task{} = task, key, label, width, arguments, opts) do
    with {:ok, browser, session} <- named_browser(task, arguments, opts),
         {:ok, file, picture} <- Tools.capture_browser_evidence(session, task, label, key: key, width: width),
         {:ok, %{commit: commit}} <- Pipeline.save_screen(task, %{key: key, label: label, file: file, browser: browser}) do
      {:ok,
       "Saved as #{file}, the image of #{key} on #{String.slice(commit || "no commit", 0, 7)}, and the picture " <>
         "is attached. Check now that it shows the state its label says, and save it again if it does not. Cite " <>
         "the path in your report for a finding that turns on this screen." <> if(width, do: @unsized, else: ""), picture}
    else
      {:error, :flat_screenshot} ->
        {:refused,
         "Refused, nothing saved. The picture came back all one color, so the page had not painted or the tab " <>
           "is still blank. Wait for the state to show, then save it again. If the page really renders blank, " <>
           "report that with its URL and the steps that reach it, as text."}

      {:refused, said} ->
        {:refused, said}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp width?(width) when is_integer(width) and width in 320..1920, do: true
  defp width?(nil), do: true
  defp width?(_width), do: false
end
