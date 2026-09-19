defmodule Rail.Mcp.Utils.RunToolQaPlan do
  @moduledoc """
  Writes the checklist a QA pass is about to work to.

  Called before anything is opened, so it does not touch the browser. A pass that
  writes its checklist and then stops has still told the human what it meant to
  do.

  Only the three fields a pass may state are taken off what arrived: an outcome
  smuggled into the plan is not a check anybody ran.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @stated ["key", "title", "group", "criterion"]

  @doc """
  Records `arguments["checks"]` as `task`'s checklist and says what was written.
  """
  def run_tool_qa_plan(%Task{} = task, %{"checks" => checks}, _opts) when is_list(checks) do
    listed = checks |> Enum.filter(&is_map/1) |> Enum.map(&Map.take(&1, @stated))

    case Pipeline.write_qa_checklist(task, listed) do
      {:ok, checklist} ->
        {:ok, "Checklist written: #{length(checklist.checks)} checks. Mark each one with qa_check as you run it."}

      {:error, _refused} ->
        {:ok,
         "That checklist was not usable. Every check needs a `key` that is lowercase and hyphenated " <>
           "and unique in the list, and a `title`. Nothing was written."}
    end
  end

  def run_tool_qa_plan(%Task{}, _arguments, _opts), do: {:ok, "qa_plan needs a `checks` list. Nothing was written."}
end
