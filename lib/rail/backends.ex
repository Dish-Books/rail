defmodule Rail.Backends do
  @moduledoc """
  Context facade for CLI backend accounts, usage probes, model registry discovery, and refresh jobs.
  """

  alias Rail.Backends.Actions

  defdelegate list_accounts(scope \\ nil, opts \\ []), to: Actions.ListAccounts

  defdelegate get_account(backend), to: Actions.GetAccount
  defdelegate get_account(scope, backend), to: Actions.GetAccount
  defdelegate get_account(scope, backend, opts), to: Actions.GetAccount

  defdelegate refresh_usage(scope \\ nil, opts \\ []), to: Actions.RefreshUsage

  defdelegate fetch_available_models(backend), to: Actions.FetchAvailableModels
  defdelegate fetch_available_models(scope, backend), to: Actions.FetchAvailableModels
  defdelegate fetch_available_models(scope, backend, opts), to: Actions.FetchAvailableModels
end
