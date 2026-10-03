defmodule Rail.Learnings.Utils.RunCuratorRole do
  @moduledoc """
  Runs a project's curator role to completion in a directory and reads back the
  `result.json` it writes there. Like a triage pass, it is not a pipeline run.
  """

  alias Rail.Pipeline
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Tools

  @timeout to_timeout(minute: 30)

  @doc """
  Runs the curator over `brief` with `dir` as its working directory. Returns
  `{:ok, result}`, or an error naming why there is none.
  """
  def run_curator_role(%Project{id: project_id}, dir, brief) do
    result = Path.join(dir, "result.json")

    with {:ok, role} <- role(project_id),
         :ok <- File.mkdir_p(dir),
         _cleared = File.rm(result),
         {:ok, _output} <- agent(role, dir, brief),
         {:ok, content} <- File.read(result),
         {:ok, %{} = decoded} <- Jason.decode(content) do
      {:ok, decoded}
    else
      {:error, reason} when reason in [:no_role, :timeout, :dispatch_disabled] -> {:error, reason}
      {:error, {:exit, _code} = exit} -> {:error, exit}
      _missing_or_malformed -> {:error, :unreadable}
    end
  end

  defp role(project_id) do
    case Roles.get_role(project_id: project_id, stage: :curator) do
      {:ok, role} -> {:ok, role}
      {:error, :role_not_found} -> {:error, :no_role}
    end
  end

  defp agent(role, dir, brief) do
    prompt = Pipeline.build_prompt(backend: role.backend, role_instructions: role.system_prompt, context_snippet: brief)

    args =
      Tools.build_args(
        backend: role.backend,
        prompt: prompt,
        model: role.model,
        reasoning_effort: to_string(role.reasoning_effort || :high),
        system_prompt: role.system_prompt,
        work_dir: dir
      )

    Tools.run_agent(role.backend, args, cd: dir, timeout: @timeout)
  end
end
