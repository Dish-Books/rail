defmodule Rail.Backends.Actions.FetchAvailableModels do
  @moduledoc false

  alias Rail.Backends.ModelRegistry

  def fetch_available_models(backend) when is_atom(backend) or is_binary(backend) do
    fetch_available_models(nil, backend, [])
  end

  def fetch_available_models(scope, backend) when is_atom(backend) or is_binary(backend) do
    fetch_available_models(scope, backend, [])
  end

  def fetch_available_models(backend, opts) when (is_atom(backend) or is_binary(backend)) and is_list(opts) do
    fetch_available_models(nil, backend, opts)
  end

  def fetch_available_models(_scope, backend, opts) do
    ModelRegistry.fetch_available_models(backend, opts)
  end
end
