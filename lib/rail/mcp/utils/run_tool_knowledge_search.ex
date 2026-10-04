defmodule Rail.Mcp.Utils.RunToolKnowledgeSearch do
  @moduledoc """
  Searches the project's rules for an agent about to ask, depart from the plan or touch something unfamiliar.
  It takes the role, not a task, since a triage pass has none; a missing query or a search that cannot run answers in a sentence.
  """

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Roles.Schemas.Role

  @limit 10

  @doc """
  Returns the ten rules nearest `arguments["query"]` among the active and
  provisional ones for `role`'s project and stage.
  """
  def run_tool_knowledge_search(%Role{} = role, %{"query" => query}, _opts) when is_binary(query) do
    if String.trim(query) == "",
      do: run_tool_knowledge_search(role, %{}, []),
      else: search(role, query)
  end

  def run_tool_knowledge_search(%Role{}, _arguments, _opts) do
    {:ok, "knowledge_search needs a `query`: what you are about to decide, ask or change. Nothing was searched."}
  end

  defp search(%Role{project_id: project_id, stage: stage}, query) do
    case Learnings.list_learnings(
           project_id: project_id,
           role: stage,
           statuses: [:active, :provisional],
           query: query,
           limit: @limit
         ) do
      {:ok, []} ->
        {:ok, "No rule this project has learned matches that."}

      {:ok, rules} ->
        {:ok, Enum.map_join(rules, "\n", &line/1)}

      {:error, _unembeddable} ->
        {:ok, "The knowledge base cannot be searched right now. Carry on without it."}
    end
  end

  defp line(%Learning{} = rule) do
    why = if rule.why, do: "\n  Why: " <> String.replace(rule.why, "\n", "\n  "), else: ""
    "- `#{rule.id}` #{Learning.kind_label(rule.kind)}: #{rule.rule}#{why}"
  end
end
