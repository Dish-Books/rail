defmodule Rail.Tools.Actions.ListModels do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.Schemas.Backend

  @doc """
  Every model the configured accounts offer, one per CLI and model id, each with
  the `backends` offering it, in the order the backends and their models were added.
  """
  def list_models do
    backends = Repo.all(from b in Backend, order_by: [asc: b.inserted_at, asc: b.id])

    {keys, models} =
      for %Backend{} = backend <- backends, model <- backend.models, reduce: {[], %{}} do
        {keys, models} ->
          key = {backend.name, model.id}

          case models do
            %{^key => entry} ->
              {keys, %{models | key => %{entry | backends: [backend | entry.backends]}}}

            %{} ->
              entry = %{cli: backend.name, id: model.id, display_name: model.display_name, backends: [backend]}
              {[key | keys], Map.put(models, key, entry)}
          end
      end

    keys
    |> Enum.reverse()
    |> Enum.map(fn key -> %{models[key] | backends: Enum.reverse(models[key].backends)} end)
  end
end
