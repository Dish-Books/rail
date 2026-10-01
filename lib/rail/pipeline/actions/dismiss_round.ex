defmodule Rail.Pipeline.Actions.DismissRound do
  @moduledoc """
  Closes a round the human dismissed in full, without a message to the agent.

  A run parked on it rests as stopped, the way `stop_run/3` leaves it, until the human chats or approves.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.UnsentRound

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  @doc """
  Dismisses `run`'s unsent round and returns the run as it is afterwards.

  Returns `{:error, :questions_pending}` while anything is open, `{:error, :answers_to_send}` when
  something was answered, and `{:error, :nothing_to_send}` when there is no round.
  """
  def dismiss_round(%Run{role: %Role{}} = run) do
    round = unsent_round(run)

    cond do
      Enum.any?(round, &(&1.status == :pending)) -> {:error, :questions_pending}
      round == [] -> {:error, :nothing_to_send}
      Enum.any?(round, &(&1.status == :answered)) -> {:error, :answers_to_send}
      true -> close(run, round)
    end
  end

  defp close(%Run{} = run, round) do
    {:ok, closed} =
      Repo.transaction(fn ->
        now = DateTime.utc_now()

        Repo.update_all(
          from(q in Question, where: q.id in ^Enum.map(round, & &1.id)),
          set: [delivered_at: now, updated_at: now]
        )

        # A run something else already resumed, such as a rebase, is not this round's to stop.
        case Repo.get!(Run, run.id) do
          %Run{status: :blocked_on_input} = parked -> parked |> Run.changeset(%{status: :finished}) |> Repo.update!()
          %Run{} = moved_on -> moved_on
        end
      end)

    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:run_changed, run.id})
    Pipeline.append_run_events(run.id, nil, ["[rail] Questions dismissed. Nothing was sent to #{run.role.name}."])

    {:ok, closed}
  end
end
