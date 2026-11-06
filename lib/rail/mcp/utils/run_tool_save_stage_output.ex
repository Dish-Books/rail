defmodule Rail.Mcp.Utils.RunToolSaveStageOutput do
  @moduledoc """
  Saves the markdown file a custom stage's agent writes as its output.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Saves `arguments["markdown"]` as the output of the custom stage `task` is at, or says why it was refused.
  """
  def run_tool_save_stage_output(%Task{} = task, arguments, _opts) do
    case Pipeline.save_stage_output(task, %{markdown: to_string(arguments["markdown"])}) do
      {:ok, _markdown} ->
        {:ok,
         "Saved. Saving again replaces it. End your turn now: a person reads it, and comments on it come back to you as a message."}

      {:error, :empty_output} ->
        {:refused, "Nothing saved: `markdown` is empty. Write the whole file."}

      {:error, {:invalid_stage, _stage}} ->
        {:refused, "Nothing saved: this stage was approved, so its file can no longer change."}
    end
  end
end
