defmodule Rail.Tools.Actions.SubmitBackendLoginCode do
  @moduledoc false

  alias Rail.Tools.LoginSession

  @doc """
  Finishes a sign-in started by `start_backend_login/3` with the code the
  sign-in page showed. Returns `:ok` once the CLI has signed in, or the reason it
  did not.
  """
  def submit_backend_login_code(_scope, session, code) when is_pid(session) and is_binary(code) do
    LoginSession.submit_code(session, String.trim(code))
  catch
    :exit, _reason -> {:error, :login_exited}
  end
end
