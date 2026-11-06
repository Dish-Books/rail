defmodule Rail.Pipeline.Utils.CheckUnsent do
  @moduledoc """
  Approving deletes every unsent plan comment on the task, so the approver's own wait until they are sent or removed.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  @doc """
  Returns `:ok`, or `{:error, {:unsent_comments, count}}` while the scope's user has that many plan comments unsent
  on `task`. A scope with no user has none.
  """
  def check_unsent(%Scope{user: %{id: _user_id}} = scope, %Task{} = task) do
    case length(Pipeline.list_plan_comments(scope, task)) do
      0 -> :ok
      count -> {:error, {:unsent_comments, count}}
    end
  end

  def check_unsent(%Scope{}, %Task{}), do: :ok
end
