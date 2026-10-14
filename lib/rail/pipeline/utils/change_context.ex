defmodule Rail.Pipeline.Utils.ChangeContext do
  @moduledoc false

  import Rail.Pipeline.Utils.FormatComments
  import Rail.Pipeline.Utils.FormatFindings
  import Rail.Pipeline.Utils.FormatTicket

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  @doc """
  What every agent checking a change is told about it, as the end of its brief: the round's plan, the reports the
  agents before it saved, the findings already on the task, the ticket and its comments. Requires `task`'s
  `project` and its `issue` with comments loaded.
  """
  def change_context(%Task{issue: %Issue{} = issue} = task) do
    String.trim("""
    #{plan(task)}
    #{reports(task)}#{format_findings(task)}
    The ticket the change was built from:

    #{format_ticket(issue)}
    Every comment on the issue, oldest first. This is the whole of its discussion.

    #{format_comments(issue.comments)}
    """)
  end

  defp plan(%Task{project: %Project{} = project} = task) do
    read = "Read the change with `git diff origin/#{project.default_branch}...HEAD`."

    case Pipeline.read_plan(task) do
      %Round{number: number, plan: content, approved_at: %DateTime{}} when is_binary(content) ->
        "This is round #{number}. #{read} The round's approved plan is the specification: where it named a file and what changed in it, that is what should have changed, and a change that did something else instead, or stopped short of it, is wrong however good the code is.\n\n#{String.trim(content)}\n"

      _unapproved ->
        "#{read} There is no approved plan for this round, so the ticket below is the whole specification.\n"
    end
  end

  defp reports(%Task{} = task) do
    Enum.map_join(Pipeline.read_reports(task), fn {role, report} ->
      "The report #{who(role)} saved this round:\n\n<report from=\"#{role}\">\n#{report}\n</report>\n\n"
    end)
  end

  defp who(:engineer), do: "the engineer"
  defp who(:qa), do: "QA"
  defp who(:review), do: "the code reviewer"
end
