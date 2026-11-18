defmodule Rail.Todos.Actions.AddLinkTodo do
  @moduledoc false

  import Rail.Todos.Utils.BroadcastTodosChanged
  import Rail.Todos.Utils.LockTodos
  import Rail.Todos.Utils.PlaceTodo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Todos.Schemas.Todo
  alias Rail.Triage
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users.Schemas.User

  # Rail's section pages, by their path's segments.
  @pages %{
    [] => "Overview",
    ["issues"] => "Issues",
    ["triage"] => "Triage",
    ["testing"] => "Testing",
    ["learnings"] => "Learnings",
    ["sandboxes"] => "Sandboxes"
  }

  @doc """
  Adds a to-do for a dropped link at `place`, named from the Rail record it points at when the scope can see
  one, else by the dragged `text`, else by the address.
  """
  def add_link_todo(%Scope{user: %User{id: user_id}} = scope, url, text, place) when is_binary(url) and is_binary(text) do
    title = record_title(scope, URI.parse(url)) || text
    title = if String.trim(title) == "", do: url, else: title
    body = title |> String.split() |> Enum.join(" ") |> String.slice(0, 500)

    result =
      Repo.transaction(fn ->
        :ok = lock_todos(user_id)

        case %Todo{user_id: user_id} |> Todo.link_changeset(%{body: body, url: url}) |> Repo.insert() do
          {:ok, todo} ->
            :ok = place_todo(user_id, todo.id, place)
            Repo.get!(Todo, todo.id)

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, _todo} <- result, do: broadcast_todos_changed(user_id)
    result
  end

  def add_link_todo(_scope, _url, _text, _place), do: {:error, :not_authenticated}

  defp record_title(scope, %URI{scheme: nil, host: nil, path: "/" <> _rest = path, query: query}) do
    rail_record_title(scope, String.split(path, "/", trim: true), URI.decode_query(query || ""))
  end

  defp record_title(scope, %URI{host: "github.com", path: "/" <> _rest = path}) do
    with [owner, repo, "pull", number | _rest] <- String.split(path, "/", trim: true),
         [%Task{} = task | _later] <-
           Pipeline.list_tasks(
             pr_url: "https://github.com/#{owner}/#{repo}/pull/#{number}",
             project_id: Scope.project_ids(scope),
             include_cleaned_up: true,
             preload: [:issue]
           ) do
      "#{task.issue.identifier} #{task.issue.title} (pull request ##{number})"
    else
      _not_a_task -> nil
    end
  end

  defp record_title(_scope, _uri), do: nil

  defp rail_record_title(scope, ["tasks", id | _rest], query) do
    with {:ok, %Task{} = task} <- Pipeline.get_task(id),
         true <- Scope.can_access_project?(scope, task.project_id) do
      task = shown_task(task, query["child"])
      findings = if query["finding"], do: Pipeline.list_findings(task), else: []

      case Enum.find(findings, &(&1.key == query["finding"])) do
        %Finding{title: title} -> "#{task.issue.identifier} finding: #{title}"
        nil -> "#{task.issue.identifier} #{task.issue.title}"
      end
    else
      _unseen -> nil
    end
  end

  defp rail_record_title(scope, [section, id], _query) when section in ["issues", "testing"] do
    with {:ok, %Issue{} = issue} <- Issues.get_issue(id, preload: []),
         true <- Scope.can_access_project?(scope, issue.project_id) do
      "#{issue.identifier} #{issue.title}"
    else
      _unseen -> nil
    end
  end

  # The thread's own lookup leaves out projects the scope cannot see.
  defp rail_record_title(scope, ["triage", id], _query) do
    case Triage.get_triage_thread(scope, id) do
      {:ok, %Thread{title: "" <> title}} -> "Triage: #{title}"
      _untitled_or_unseen -> nil
    end
  end

  defp rail_record_title(scope, ["learnings", "proposals", id], _query) do
    with {:ok, %LearningProposal{title: "" <> title} = proposal} <- Learnings.get_learning_proposal(id),
         true <- Scope.can_access_project?(scope, proposal.project_id) do
      "Learning proposal: #{title}"
    else
      _untitled_or_unseen -> nil
    end
  end

  defp rail_record_title(scope, ["learnings", id], _query) do
    with {:ok, %Learning{} = learning} <- Learnings.get_learning(id),
         true <- Scope.can_access_project?(scope, learning.project_id) do
      "Learning: #{learning.rule}"
    else
      _unseen -> nil
    end
  end

  defp rail_record_title(_scope, ["settings" | _rest], _query), do: "Settings"

  defp rail_record_title(_scope, segments, _query), do: Map.get(@pages, segments)

  # A split's page names its child in the address, by the child's identifier; the child shares its project.
  defp shown_task(task, nil), do: task

  defp shown_task(task, child) do
    [parent_task_id: task.id, preload: [:issue]]
    |> Pipeline.list_tasks()
    |> Enum.find(task, &(&1.issue.identifier == child))
  end
end
