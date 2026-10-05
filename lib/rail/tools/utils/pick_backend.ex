defmodule Rail.Tools.Utils.PickBackend do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  # A turn counts against its account from the moment it is stamped until it ends.
  @in_flight [:starting, :running, :waiting_for_resources]

  # An account used up with no reset reported is looked at again once the next usage refresh has run.
  @unknown_reset_seconds 5 * 60

  @doc """
  Picks the account a conversation on `model` runs on: `pinned`, the one a
  resumed conversation lives on, or the signed-in account of `cli` offering
  `model` that stands highest once its standing is shared among its turns in
  flight. Ties go to fewer turns in flight, then to the account added first.

  Returns `{:ok, backend}`, `{:wait, resets_at}` when every account it could go
  to is used up, `{:error, :no_account}` when none offers `model`, or
  `{:error, {:signed_out, pinned}}`.
  """
  def pick_backend(cli, model, pinned)

  def pick_backend(_cli, model, %Backend{status: :ready} = pinned) do
    case Backend.calculate_standing(pinned, model) do
      %{used_up: []} -> {:ok, pinned}
      %{resets_at: resets_at} -> {:wait, resets_at || unknown_reset()}
    end
  end

  def pick_backend(_cli, _model, %Backend{} = pinned), do: {:error, {:signed_out, pinned}}

  def pick_backend(cli, model, nil) do
    offering =
      from(b in Backend, where: b.name == ^cli and b.status == :ready, order_by: [asc: b.inserted_at, asc: b.id])
      |> Repo.all()
      |> Enum.filter(fn %Backend{models: models} -> Enum.any?(models, &(&1.id == model)) end)

    ids = Enum.map(offering, & &1.id)
    now = DateTime.utc_now()

    in_flight =
      Map.new(
        Repo.all(
          from p in OsProcess,
            where: p.backend_id in ^ids and p.status in ^@in_flight,
            group_by: p.backend_id,
            select: {p.backend_id, count()}
        )
      )

    ranked =
      offering
      |> Enum.with_index()
      |> Enum.map(fn {backend, order} ->
        {backend, Backend.calculate_standing(backend, model, now), Map.get(in_flight, backend.id, 0), order}
      end)

    case Enum.filter(ranked, fn {_backend, standing, _turns, _order} -> standing.used_up == [] end) do
      [] when ranked == [] ->
        {:error, :no_account}

      [] ->
        {:wait,
         Enum.min(
           Enum.map(ranked, fn {_backend, standing, _turns, _order} -> standing.resets_at || unknown_reset() end),
           DateTime
         )}

      room ->
        {backend, _standing, _turns, _order} =
          Enum.min_by(room, fn {_backend, standing, turns, order} -> {-standing.standing / (turns + 1), turns, order} end)

        {:ok, backend}
    end
  end

  defp unknown_reset, do: DateTime.shift(DateTime.utc_now(), second: @unknown_reset_seconds)
end
