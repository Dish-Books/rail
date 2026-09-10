defmodule Rail.Backends.Actions.GetBackend do
  @moduledoc false

  alias Rail.Backends.Schemas.Backend
  alias Rail.Repo

  def get_backend(name) when is_atom(name) or is_binary(name) do
    get_backend(nil, name)
  end

  def get_backend(_scope, name) do
    case normalize_name(name) do
      {:ok, value} -> Repo.get_by(Backend, name: value)
      :error -> nil
    end
  end

  defp normalize_name(name) when is_atom(name) do
    if name in Backend.names(), do: {:ok, name}, else: :error
  end

  defp normalize_name(name) when is_binary(name) do
    Enum.find_value(Backend.names(), :error, fn value ->
      if Atom.to_string(value) == String.downcase(name), do: {:ok, value}
    end)
  end
end
