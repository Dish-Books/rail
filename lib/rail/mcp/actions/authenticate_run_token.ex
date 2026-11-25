defmodule Rail.Mcp.Actions.AuthenticateRunToken do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Support.Schemas.Conversation
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Triage.Schemas.Thread

  @triage_minutes 45

  @doc """
  Resolves a run token to the turn presenting it. A token is only good while its
  OS process is live, or while the triage, support or issue chat pass it was minted for holds its
  thread, conversation or issue, so a finished turn's token is dead even if it leaked.
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
        with {:error, :invalid_token} <- triage(hash),
             {:error, :invalid_token} <- support(hash),
             do: issue_chat(hash)
    end
  end

  def authenticate_run_token(_token), do: {:error, :invalid_token}

  defp triage(hash) do
    since = DateTime.shift(DateTime.utc_now(), minute: -@triage_minutes)

    query =
      from t in Thread,
        where: t.mcp_token_hash == ^hash and t.triage_started_at > ^since,
        preload: [project: :triage_user]

    with %Thread{project: project} <- Repo.one(query),
         {:ok, role} <- Roles.get_role(project_id: project.id, stage: :triage) do
      {:ok, %RunContext{os_process: nil, role: role, user: project.triage_user}}
    else
      _no_pass -> {:error, :invalid_token}
    end
  end

  # A support pass runs on the project's Triage role, as its triage user.
  defp support(hash) do
    since = DateTime.shift(DateTime.utc_now(), minute: -@triage_minutes)

    query =
      from c in Conversation,
        where: c.mcp_token_hash == ^hash and c.agent_started_at > ^since,
        preload: [project: :triage_user]

    with %Conversation{project: project} <- Repo.one(query),
         {:ok, role} <- Roles.get_role(project_id: project.id, stage: :triage) do
      {:ok, %RunContext{os_process: nil, role: role, user: project.triage_user}}
    else
      _no_pass -> {:error, :invalid_token}
    end
  end

  # An issue chat pass runs on its project's Triage role, as its triage user, as Support's does.
  defp issue_chat(hash) do
    since = DateTime.shift(DateTime.utc_now(), minute: -@triage_minutes)

    query =
      from i in Issue,
        where: i.chat_token_hash == ^hash and i.chat_started_at > ^since,
        preload: [project: :triage_user]

    with %Issue{project: project} <- Repo.one(query),
         {:ok, role} <- Roles.get_role(project_id: project.id, stage: :triage) do
      {:ok, %RunContext{os_process: nil, role: role, user: project.triage_user}}
    else
      _no_pass -> {:error, :invalid_token}
    end
  end
end
