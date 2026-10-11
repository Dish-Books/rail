defmodule Rail.Mcp.Utils.RunToolSaveReview do
  @moduledoc """
  Closes a Review round once every finding in it is saved.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Records that the round running on `task` is finished, and says which round it was.
  """
  def run_tool_save_review(%Task{} = task, _arguments, _opts) do
    case Pipeline.save_review(task) do
      {:ok, %{round: round}} ->
        {:ok, "Round #{round} saved. The round is finished; end the turn with what it found."}

      {:error, {:review_finished, stage}} ->
        {:refused,
         "Nothing saved: the review is finished and #{where(stage)}, so there is no round to report. " <>
           "Answer in the conversation instead."}
    end
  end

  defp where(:finalize), do: "the task is at Finalize"
  defp where(:merged), do: "the task has merged"
end
