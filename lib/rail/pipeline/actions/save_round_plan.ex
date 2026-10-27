defmodule Rail.Pipeline.Actions.SaveRoundPlan do
  @moduledoc """
  Saves a round's plan in place of the one before it. A plan changes only until it is approved, since the round's
  work starts from what was approved.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Repo

  @doc """
  Saves `attrs["plan"]` as the next version of `round`'s plan. Returns `{:ok, round}`, `{:error, :round_approved}`
  once it is approved, or `{:error, changeset}` naming what to fix.
  """
  def save_round_plan(%Round{id: id}, attrs) when is_map(attrs) do
    # Read again, so a save after another one is the version after it.
    case Round |> Repo.get!(id) |> Repo.preload(:task) do
      %Round{approved_at: %DateTime{}} ->
        {:error, :round_approved}

      %Round{} = round ->
        with {:ok, saved} <- round |> Round.plan_changeset(attrs) |> Repo.update() do
          Pipeline.broadcast_output_saved(round.task)
          {:ok, saved}
        end
    end
  end
end
