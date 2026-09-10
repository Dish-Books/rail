defmodule Rail.Backends do
  @moduledoc """
  Context facade for CLI backend accounts, usage probes, model discovery, and refresh jobs.
  """

  use Rail.PermissionsDecorator

  alias Rail.Backends.Actions
  alias Rail.Backends.Schemas

  defdelegate list_accounts(scope \\ nil, opts \\ []), to: Actions.ListAccounts

  defdelegate get_account(backend), to: Actions.GetAccount
  defdelegate get_account(scope, backend), to: Actions.GetAccount
  defdelegate get_account(scope, backend, opts), to: Actions.GetAccount

  defdelegate refresh_usage(scope \\ nil, opts \\ []), to: Actions.RefreshUsage

  defdelegate backend_names(), to: Schemas.Backend, as: :names

  defdelegate list_backends(scope \\ nil), to: Actions.ListBackends

  defdelegate get_backend(name), to: Actions.GetBackend
  defdelegate get_backend(scope, name), to: Actions.GetBackend

  @decorate can?(resource: :backends, action: :manage)
  defdelegate create_backend(scope, attrs), to: Actions.CreateBackend

  @decorate can?(resource: :backends, action: :manage)
  defdelegate update_backend(scope, backend, attrs), to: Actions.UpdateBackend
end
