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
  alias Rail.Pipeline.Schemas.QaCheck
  alias Rail.Pipeline.Schemas.QaChecklist
  alias Rail.Pipeline.Schemas.Task

  @stated ["key", "title", "group", "criterion"]

  @doc """
  Records `arguments["checks"]` as `task`'s checklist and says what was written.
  """
  def run_tool_qa_plan(%Task{} = task, %{"checks" => checks}, _opts) when is_list(checks) do
    listed = checks |> Enum.filter(&is_map/1) |> Enum.map(&Map.take(&1, @stated))

    case Pipeline.write_qa_checklist(task, listed) do
      {:ok, checklist} ->
        {:ok, written(checklist)}

      {:error, _refused} ->
        {:ok,
         "That checklist was not usable. Every check needs a `key` that is lowercase and hyphenated " <>
           "and unique in the list, and a `title`. Nothing was written."}
    end
  end

  def run_tool_qa_plan(%Task{}, _arguments, _opts), do: {:ok, "qa_plan needs a `checks` list. Nothing was written."}

  # A row an earlier pass answered is answered. Saying so here is what stops the
  # whole list being driven a second time: the pass reads this receipt, not the
  # file, and a receipt that says "mark each one as you run it" is an instruction
  # to run all of them.
  defp written(%QaChecklist{checks: checks}) do
    case Enum.split_with(checks, & &1.carried) do
      {[], _run_these} ->
        "Checklist written: #{length(checks)} checks. Mark each one with qa_check as you run it."

      {carried, []} ->
        "Checklist written: #{length(checks)} checks, and an earlier pass answered every one of them: " <>
          "#{keys(carried)}. Nothing here needs driving again unless the new commits could have changed " <>
          "what it asserts."

      {carried, run_these} ->
        "Checklist written: #{length(checks)} checks. #{length(carried)} of them keep the answer an " <>
          "earlier pass gave: #{keys(carried)}. Leave those alone - they already count - unless the new " <>
          "commits could have changed what one of them asserts, in which case driving it again and " <>
          "marking it with qa_check is how you overrule it. Run these #{length(run_these)} and mark each " <>
          "with qa_check as you go: #{keys(run_these)}."
    end
  end

  defp keys(checks), do: Enum.map_join(checks, ", ", fn %QaCheck{key: key} -> key end)
end
