defmodule Rail.Mcp.Utils.RunToolSaveDesignOption do
  @moduledoc """
  Saves one of the designer's options once its page and screenshot exist.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @fields ["key", "title", "summary", "good_at", "costs", "assumptions"]

  @doc """
  Saves the option in `arguments` on `task` and says which, or hands back the
  changeset that refused it.
  """
  def run_tool_save_design_option(%Task{} = task, arguments, _opts) do
    with {:ok, %{key: key, title: title}} <- Pipeline.save_design_option(task, Map.take(arguments, @fields)) do
      {:ok, "Saved option #{key}: #{title}. Save it again whenever its page changes, with a fresh screenshot."}
    end
  end
end
