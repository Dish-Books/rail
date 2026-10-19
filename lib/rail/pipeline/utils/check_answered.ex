defmodule Rail.Pipeline.Utils.CheckAnswered do
  @moduledoc """
  A plan is approved or started only once every question its task asked is answered or dismissed, since the
  plan may turn on the answer.
  """

  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Pipeline.Schemas.Task

  @doc "Returns `:ok`, or `{:error, {:unanswered_questions, count}}` while `task` waits on that many questions."
  def check_answered(%Task{id: task_id}) do
    case length(pending_questions(task_id)) do
      0 -> :ok
      count -> {:error, {:unanswered_questions, count}}
    end
  end
end
