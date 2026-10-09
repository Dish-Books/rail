defmodule Rail.Pipeline.Utils.LearningsBrief do
  @moduledoc """
  The rules a run is given as it starts, as a section of its brief: a list for most roles, and for the Review
  lead a checklist with ids and the instruction to still write up what a calibration rule says not to raise.
  """

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  @doc """
  Returns `run`'s rules section for `queries`, a list or a function building one only when needed, or `""` on an answer turn,
  which `build_prompt/1` sends without the brief.
  """
  def learnings_brief(%Run{pending_answer: answer} = run, queries) do
    if is_binary(answer) and String.trim(answer) != "" do
      ""
    else
      %Run{role: %Role{stage: stage}} = run = Repo.preload(run, :role)
      queries = if is_function(queries, 0), do: queries.(), else: queries

      run
      |> Learnings.retrieve_learnings(queries)
      |> section(stage)
    end
  end

  defp section([], _stage), do: ""

  defp section(rules, :review_lead) do
    """

    The checklist: rules this project has learned. Hand each subagent every one that bears on its work, word for word, since a subagent sees only what you write it. Check the change against every one that applies to the files it touches, and when a finding comes from one, give that rule's id as `checklist_rule` in the finding.

    #{Enum.map_join(rules, "\n", &line(&1, true))}

    A calibration rule says what not to raise. A finding one says not to raise is still saved, with that rule's id as `checklist_rule`: Rail sets it apart for a person rather than dropping it, so leaving it out loses the record that the rule held.
    """
  end

  defp section(rules, _stage) do
    """

    What this project has learned. People set these rules or corrected an agent into them, so follow every one that applies to this work. Call `knowledge_search` for more before you ask a question, depart from the plan, or work in a module you do not know.

    #{Enum.map_join(rules, "\n", &line(&1, false))}
    """
  end

  defp line(%Learning{} = rule, with_id?) do
    id = if with_id?, do: "`#{rule.id}` ", else: ""
    provisional = if rule.status == :provisional, do: " (provisional, from a recent correction)", else: ""
    glob = if rule.path_glob, do: " Applies to `#{rule.path_glob}`.", else: ""
    why = if rule.why, do: "\n  Why: " <> String.replace(rule.why, "\n", "\n  "), else: ""

    "- #{id}#{Learning.kind_label(rule.kind)}#{provisional}: #{rule.rule}#{glob}#{why}"
  end
end
