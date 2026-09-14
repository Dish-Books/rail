defmodule Rail.Mcp.Actions.AuthenticateRunToken do
  @moduledoc false

  import Ecto.Query

  alias Rail.Mcp.RunContext
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Resolves a run token to the turn presenting it. A token is only good while its
  OS process is live, so a finished turn's token is dead even if it leaked.
  """
  def authenticate_run_token(token) when is_binary(token) and token != "" do
    hash = :crypto.hash(:sha256, token)

    query =
      from p in OsProcess,
        where: p.mcp_token_hash == ^hash and p.status in [:starting, :running],
        preload: [run: [:role, task: [issue: :owner_user]]]

    case Repo.one(query) do
      %OsProcess{run: %Run{role: role, task: task}} = os_process ->
        {:ok, %RunContext{os_process: os_process, role: role, user: task.issue.owner_user}}

      nil ->
        {:error, :invalid_token}
    end
  end

  def authenticate_run_token(_token), do: {:error, :invalid_token}
end
