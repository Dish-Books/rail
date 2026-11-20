defmodule Rail.Mcp.Utils.RunToolSaveDesignOption do
  @moduledoc """
  Saves one of the designer's options once its page and screenshot exist.

  Plan draws web screens from the running app, never from the code alone, so at Plan an option is refused until a
  browser of the task's has opened on the app. The review agent revises the picked option from what Plan drew, and is
  not asked.
  """

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools.Schemas.BrowserSession

  @fields ["key", "title", "summary", "good_at", "costs", "assumptions"]

  @doc """
  Saves the option in `arguments` on `task` and says which, or hands back the
  changeset that refused it.
  """
  def run_tool_save_design_option(%Task{} = task, arguments, opts) do
    if Keyword.get(opts, :stage) == :plan and not browsed?(task),
      do: {:refused, unbrowsed()},
      else: save(task, arguments)
  end

  defp save(%Task{} = task, arguments) do
    case Pipeline.save_design_option(task, Map.take(arguments, @fields)) do
      {:ok, %{key: key, title: title}} ->
        {:ok, "Saved option #{key}: #{title}. Save it again whenever its page changes, with a fresh screenshot."}

      {:error, {:step_off, :design}} ->
        {:refused, "Nothing saved: Design is off for this task, so it has no design options."}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # A browser opened on the app is one that got as far as being signed in, as whoever it was opened as.
  defp browsed?(%Task{id: task_id}),
    do: Repo.exists?(from s in BrowserSession, where: s.task_id == ^task_id and not is_nil(s.signed_in_at))

  defp unbrowsed do
    "Nothing saved: no browser has opened on the running app for this task yet, and a web screen is drawn from the " <>
      "app as it renders, never from the code alone. Open the app for a phone change too, for its data and look. " <>
      "Call browser_connect, look at the screens the change touches, then save. If the browser cannot start, Rail " <>
      "fails the plan and says why."
  end
end
