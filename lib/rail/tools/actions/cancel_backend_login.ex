defmodule Rail.Tools.Actions.CancelBackendLogin do
  @moduledoc false

  @doc "Abandons a sign-in, stopping the CLI waiting for its code."
  def cancel_backend_login(_scope, session) when is_pid(session) do
    DynamicSupervisor.terminate_child(Rail.Tools.LoginSupervisor, session)
    :ok
  end
end
