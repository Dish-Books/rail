defmodule Rail.Pipeline.Actions.StopAndSendMessage do
  @moduledoc """
  Delivers a queued message now rather than waiting for the agent to finish.

  This is the "send now" on a queued message: the turn in flight is cut short and
  the message goes out in its place. Stopping keeps everything the run has, so
  the agent reads the new message with the whole conversation behind it — what it
  loses is only the rest of the thought it was part way through, which is the
  point of interrupting.
  """

  import Rail.Pipeline.Utils.DispatchMessage

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc """
  Stops `run` and immediately sends what was queued on it.
  """
  def stop_and_send_message(%Run{} = run, opts \\ []) do
    {:ok, run, queued} = Pipeline.stop_run(run, opts)

    case queued do
      text when is_binary(text) ->
        {:ok, run} = run |> Run.changeset(%{pending_chat: text}) |> Repo.update()
        dispatch_message(run, opts)
        {:ok, :sent, run}

      nil ->
        {:error, :nothing_queued}
    end
  end
end
