defmodule Rail.Pipeline.Actions.AppendPendingAnswer do
  @moduledoc """
  Queues an answer for the next turn of a run's conversation.

  Anything already pending is kept: answers arriving from different places before
  the role is dispatched again all reach the agent, separated by a blank line.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc """
  Appends `answer` to the run's `pending_answer` and returns the updated row.

  Pass `auto_retries: 0` to reset the retry budget alongside it.
  """
  def append_pending_answer(%Run{} = run, answer, opts \\ []) do
    pending = run.pending_answer

    new_pending =
      if pending && String.trim(pending) != "", do: "#{pending}\n\n#{answer}", else: answer

    attrs =
      case Keyword.fetch(opts, :auto_retries) do
        {:ok, auto_retries} -> %{pending_answer: new_pending, auto_retries: auto_retries}
        :error -> %{pending_answer: new_pending}
      end

    run
    |> Run.changeset(attrs)
    |> Repo.update!()
  end
end
