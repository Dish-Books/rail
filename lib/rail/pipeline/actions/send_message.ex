defmodule Rail.Pipeline.Actions.SendMessage do
  @moduledoc """
  Sends a message from the human to the agent holding a run's conversation.

  There is one rule and no options: if the run is working, the message waits on
  it; if it is not, the message goes out now. Waiting is the only reason a queue
  exists, so nothing here asks what the rest of the task is doing — a message to
  an idle reviewer goes out whether or not the engineer is busy.

  Queued messages accumulate rather than replacing, so a second thought lands
  after the first one in the same turn.
  """

  import Rail.Pipeline.Utils.DispatchMessage

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc """
  Sends `text` to `run`.

  Returns `{:ok, :sent, run}` when it went out, `{:ok, :queued, run}` when the
  agent is still working and it will go out when the turn ends.
  """
  def send_message(%Run{} = run, text) do
    with %Run{} = run <- Repo.get(Run, run.id),
         :ok <- validate_can_chat(run),
         {:ok, trimmed} <- validate_message(text) do
      deliver(run, trimmed)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_can_chat(%Run{} = run) do
    if Run.can_chat?(run), do: :ok, else: {:error, :chat_unavailable}
  end

  defp validate_message(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty_message}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_message(_other), do: {:error, :empty_message}

  defp deliver(%Run{} = run, text) do
    record_transcript(run, text)
    {:ok, run} = run |> Run.changeset(%{pending_chat: append(run.pending_chat, text)}) |> Repo.update()

    if Run.running?(run) do
      {:ok, :queued, run}
    else
      dispatch_message(run)
      {:ok, :sent, run}
    end
  end

  # The human's words go into the log as they are typed, so the conversation reads
  # in order whether the agent sees them now or at the end of its turn.
  defp record_transcript(%Run{} = run, text) do
    lines = text |> String.split("\n") |> Enum.map(&"[human] #{&1}")
    Pipeline.append_run_events(run.id, nil, lines)
  end

  defp append(nil, text), do: text
  defp append(existing, text), do: "#{existing}\n\n#{text}"
end
