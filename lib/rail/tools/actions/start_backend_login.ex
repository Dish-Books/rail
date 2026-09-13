defmodule Rail.Tools.Actions.StartBackendLogin do
  @moduledoc false

  alias Rail.Tools.LoginSession
  alias Rail.Tools.Schemas.Backend

  @doc """
  Starts signing a backend in to an account, in the backend's own config
  directory, and returns the URL the user signs in at.

  The session is `owner`'s: it ends when `owner` does, and it is what
  `submit_backend_login_code/3` hands the code from the sign-in page to. When
  the CLI finishes without one, `owner` is sent
  `{:backend_login_exited, session, :ok | {:error, reason}}`.
  Only Claude Code can be signed in this way.
  """
  def start_backend_login(_scope, %Backend{name: :claude} = backend, owner) do
    with {:ok, session} <- DynamicSupervisor.start_child(Rail.Tools.LoginSupervisor, {LoginSession, {backend, owner}}),
         {:ok, url} <- await_url(session) do
      {:ok, %{session: session, url: url}}
    end
  end

  def start_backend_login(_scope, %Backend{}, _owner), do: {:error, :unsupported}

  defp await_url(session) do
    LoginSession.await_url(session)
  catch
    # coveralls-ignore-start (the session died while the URL was on its way)
    :exit, _reason ->
      {:error, :login_exited}
      # coveralls-ignore-stop
  end
end
