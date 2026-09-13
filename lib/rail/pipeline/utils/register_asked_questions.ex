defmodule Rail.Pipeline.Utils.RegisterAskedQuestions do
  @moduledoc """
  The questions one finished OS process asked, filed against its task.

  An agent step ends by asking its batch of questions, so they are read out of the
  log once the process is gone rather than off the stream as it runs. A run's log
  covers every process it spawned, so only the lines carrying this process are read:
  that is what makes a question asked in this turn distinguishable from the same
  question asked, and answered, two turns ago.
  """

  import Ecto.Query
  import Rail.Runs.Utils.NewEventState
  import Rail.Runs.Utils.ParseLine

  alias Rail.Backends.Schemas.Backend
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent

  # Everything Rail, the tools or the human contributed carries one of these
  # markers; what the agent said carries none.
  @markers [
    "[tool]",
    "[tool error]",
    "[init]",
    "[result]",
    "[denied]",
    "[recovered]",
    "[rate limit]",
    "[rail]",
    "[human]",
    "[handoff]",
    "[stderr]",
    "[error]"
  ]

  @doc """
  Registers every question `os_process` asked, in order, and returns them.

  The first registration parks the task; the rest queue up behind it, so the human
  answers them one at a time without the stage resuming in between. Returns `[]`
  when the process asked nothing, which is what tells the caller the stage is free
  to move on.
  """
  def register_asked_questions(%OsProcess{} = os_process, %Run{} = run) do
    run = Repo.preload(run, [task: :issue, role: :backend], force: true)
    questions = os_process |> agent_log(run) |> Runs.detect_questions()

    Enum.each(questions, &Pipeline.register_question(run, &1))

    questions
  end

  # The agent's own words for one OS process, oldest first.
  defp agent_log(%OsProcess{}, %Run{role: nil}), do: ""

  defp agent_log(%OsProcess{id: os_process_id}, %Run{role: %{backend: backend}}) do
    backend = if is_struct(backend, Backend), do: backend, else: %Backend{name: :claude}

    os_process_id
    |> events_from()
    |> Enum.reduce(new_event_state(backend), fn event, state ->
      parse_line(state, event.line)
    end)
    |> Map.fetch!(:logs)
    |> Enum.reject(&tagged?/1)
    |> Enum.join("\n")
  end

  defp events_from(os_process_id) do
    Repo.all(
      from e in RunEvent,
        where: e.os_process_id == ^os_process_id,
        order_by: [asc: e.seq]
    )
  end

  defp tagged?(line) when is_binary(line), do: Enum.any?(@markers, &String.starts_with?(line, &1))
  defp tagged?(_other), do: true
end
