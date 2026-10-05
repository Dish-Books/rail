defmodule Rail.Learnings.Utils.WriteRulesFile do
  @moduledoc """
  Writes a project's rules to a file a pass reads and cites by id.
  """

  import Rail.Learnings.Utils.SearchLearnings

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Projects.Schemas.Project

  @doc """
  Writes every active and provisional rule of `project` to `path`.
  """
  def write_rules_file(%Project{id: project_id, name: name}, path) do
    rules = search_learnings([project_id: project_id, statuses: [:active, :provisional]], nil)
    entries = Enum.map(rules, &entry/1)
    body = if entries == [], do: "There are no rules yet.\n", else: Enum.join(entries, "\n")

    File.write!(path, "# The rules #{name} has learned\n\n" <> body)
  end

  defp entry(%Learning{} = rule) do
    glob = if rule.path_glob, do: " · applies to `#{rule.path_glob}`", else: ""
    why = if rule.why, do: "\n\nWhy: #{rule.why}", else: ""

    """
    ## #{rule.id} · #{Learning.kind_label(rule.kind)} · #{Learning.status_label(rule.status)}

    Roles: #{Learning.roles_label(rule)}#{glob}

    #{rule.rule}#{why}
    """
  end
end
