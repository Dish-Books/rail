defmodule Rail.Pipeline.Actions.ListPlanComments do
  @moduledoc """
  The plan comments a reader sees on a task: their own unsent ones, which nobody else sees, and with `sent: true`
  everyone's queued and sent ones too.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Returns the scope user's unsent comments on `task`, of every target, in the order Send would number them.
  `sent: true` adds everyone's queued and sent ones, with their authors.
  """
  def list_plan_comments(%Scope{user: %{id: user_id}}, %Task{id: task_id}, opts \\ []) do
    seen =
      if opts[:sent],
        do: dynamic([c], c.status in [:queued, :sent] or (c.status == :unsent and c.user_id == ^user_id)),
        else: dynamic([c], c.status == :unsent and c.user_id == ^user_id)

    from(comment in PlanComment,
      where: comment.task_id == ^task_id,
      where: ^seen,
      preload: ^if(opts[:sent], do: [:user], else: [])
    )
    |> Repo.all()
    |> PlanComment.calculate_round()
  end
end
