defmodule Rail.Pipeline.Actions.ListComments do
  @moduledoc """
  Every comment a reader sees on a task, of every kind, as one list: messages people typed to an agent and comments
  on the ticket, design, plans, diff, screens and findings. Another person's unsent comments are never read.
  """

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

  @sender ~r/\A\[human:([^\]\s]+)\] ?/

  @doc """
  Returns `%{kind:, id:, at:, user:, comment:}` for each comment on `task` the scope user sees, oldest first. A
  message's `comment` is `%{body:, role:, run_id:}` and its `user` nil once its sender is gone.
  """
  def list_comments(%Scope{user: %{id: _user_id}} = scope, %Task{} = task) do
    entries =
      Enum.map(Pipeline.list_diff_comments(scope, task), &entry(:diff, &1)) ++
        Enum.map(Pipeline.list_plan_comments(scope, task, sent: true), &entry(:plan, &1)) ++
        Enum.map(Pipeline.list_screen_comments(scope, task, sent: true), &entry(:screen, &1)) ++
        Enum.map(Pipeline.list_finding_comments(scope, task, sent: true), &entry(:finding, &1)) ++
        messages(scope, task)

    Enum.sort_by(entries, &{DateTime.to_unix(&1.at, :microsecond), &1.id})
  end

  defp entry(kind, comment),
    do: %{kind: kind, id: comment.id, at: comment.inserted_at, user: comment.user, comment: comment}

  # One send writes every line of a message at one time, and a plan comment round or a round of answers is listed as
  # its comments or not at all.
  defp messages(scope, %Task{id: task_id} = task) do
    lines =
      Repo.all(
        from e in RunEvent,
          join: r in Run,
          on: r.id == e.run_id,
          join: role in assoc(r, :role),
          # The same pattern as `@sender`, so every line read names its sender.
          where: r.task_id == ^task_id and fragment("? ~ ?", e.line, "^\\[human:[^]\\s]+\\]"),
          order_by: [asc: e.run_id, asc: e.seq],
          select: {e, role}
      )

    grouped = Enum.chunk_by(lines, fn {event, _role} -> {event.run_id, event.inserted_at, sender(event.line)} end)
    questions = if grouped == [], do: [], else: Pipeline.list_questions(task)
    ids = grouped |> Enum.map(fn [{event, _role} | _rest] -> sender(event.line) end) |> Enum.uniq()
    users = if ids == [], do: %{}, else: scope |> Users.list_users_by_ids(ids) |> Map.new(&{&1.id, &1})

    for [{first, role} | _rest] = message <- grouped,
        body = Enum.map_join(message, "\n", fn {event, _role} -> Regex.replace(@sender, event.line, "") end),
        PlanComment.parse_message(body) == nil and Question.parse_answers_message(body, questions) == nil do
      %{
        kind: :message,
        id: first.id,
        at: first.inserted_at,
        user: users[sender(first.line)],
        comment: %{body: String.trim(body), role: role, run_id: first.run_id}
      }
    end
  end

  defp sender(line), do: @sender |> Regex.run(line) |> Enum.at(1)
end
