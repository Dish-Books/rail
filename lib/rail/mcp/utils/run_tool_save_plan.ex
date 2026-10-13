defmodule Rail.Mcp.Utils.RunToolSavePlan do
  @moduledoc """
  Saves the Plan agent's ticket and implementation plan, from the first draft to the last, with the design option
  the plan is written for.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task

  @fields ["title", "description", "priority", "estimate", "plan", "design"]

  @again "Save again after every change; the human reads the last save."

  @doc """
  Saves the parts of the plan in `arguments` on `task` and says what is saved, or hands back the changeset that
  refused it.
  """
  def run_tool_save_plan(%Task{} = task, arguments, _opts) do
    case Pipeline.save_plan(task, Map.take(arguments, @fields)) do
      {:ok, %Round{ticket: %{title: title}, plan: nil}} ->
        {:ok, "Ticket saved: #{title}. No implementation plan is saved yet. #{@again}"}

      {:ok, %Round{ticket: %{title: title}, design: %{key: key, title: option}}} ->
        {:ok, "Ticket saved: #{title}. Plan saved for #{option} (#{key}). #{@again}"}

      {:ok, %Round{ticket: %{title: title}, design: nil}} ->
        {:ok, "Ticket saved: #{title}. Plan saved, written for no design option yet. #{@again}"}

      {:error, :round_approved} ->
        {:refused, "Nothing saved: the plan is approved, so it no longer changes."}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
