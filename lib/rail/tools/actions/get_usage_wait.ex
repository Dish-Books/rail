defmodule Rail.Tools.Actions.GetUsageWait do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  What `run` waits on while it waits for usage: its waiting `os_process`, the
  `pinned` account its conversation lives on if any, the `model`'s display name,
  the earliest `resets_at` it can start at, and the `accounts` it waits on.

  Each account carries the `window` holding it back and when it `resets_at`,
  earliest first; one not signed in follows, not `waited_on?`. A pinned
  conversation waits on its own account alone. Returns `{:error, :not_waiting}`
  for a run not waiting for usage.
  """
  def get_usage_wait(%Run{id: run_id} = run) do
    query =
      from p in OsProcess,
        where: p.run_id == ^run_id and p.status == :waiting_for_usage,
        order_by: [desc: p.inserted_at, desc: p.id],
        limit: 1,
        preload: :backend

    case Repo.one(query) do
      %OsProcess{} = os_process -> {:ok, wait(os_process, Repo.preload(run, :role).role)}
      nil -> {:error, :not_waiting}
    end
  end

  defp wait(%OsProcess{backend: pinned} = os_process, %Role{cli: cli, model: model}) do
    now = DateTime.utc_now()

    backends =
      from(b in Backend, where: b.name == ^cli, order_by: [asc: b.inserted_at, asc: b.id])
      |> Repo.all()
      |> Enum.filter(fn %Backend{models: models} -> Enum.any?(models, &(&1.id == model)) end)

    if_result = if pinned, do: [pinned], else: backends

    accounts =
      if_result
      |> Enum.map(&account(&1, model, now))
      |> Enum.with_index()
      |> Enum.sort_by(fn {account, order} ->
        {not account.waited_on?, is_nil(account.resets_at),
         account.resets_at && DateTime.to_unix(account.resets_at, :microsecond), order}
      end)
      |> Enum.map(&elem(&1, 0))

    %{
      os_process: os_process,
      pinned: pinned,
      model: Enum.find_value(backends, model, &Enum.find_value(&1.models, fn m -> m.id == model && m.display_name end)),
      resets_at: accounts |> Enum.map(& &1.resets_at) |> Enum.reject(&is_nil/1) |> Enum.min(DateTime, fn -> nil end),
      accounts: accounts
    }
  end

  # The window holding an account back is the used-up one that resets last.
  defp account(%Backend{status: :ready} = backend, model, now) do
    standing = Backend.calculate_standing(backend, model, now)
    window = Enum.find(standing.used_up, &(&1.resets_at == standing.resets_at)) || standing.tightest
    %{backend: backend, waited_on?: true, window: window, resets_at: standing.resets_at}
  end

  defp account(%Backend{} = backend, _model, _now) do
    %{backend: backend, waited_on?: false, window: nil, resets_at: nil}
  end
end
