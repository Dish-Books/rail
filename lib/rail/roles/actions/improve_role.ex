defmodule Rail.Roles.Actions.ImproveRole do
  @moduledoc false

  alias Rail.Backends.Probes
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Tools

  def improve_role(scope, %Role{} = role, chosen_model, opts \\ []) when is_binary(chosen_model) do
    case Rail.Roles.recent_finished_runs(scope, role.id, opts) do
      [] ->
        {:error, :no_evidence}

      sources when is_list(sources) ->
        run_improvement(role, chosen_model, sources, opts)
    end
  end

  defp run_improvement(%Role{} = role, chosen_model, sources, opts) do
    unique_id = System.unique_integer([:positive])
    temp_cwd = Path.join(System.tmp_dir!(), "rail_improve_#{role.id}_#{unique_id}")
    File.mkdir_p!(temp_cwd)

    meta_prompt = Rail.Roles.build_meta_prompt(role, sources)
    improver_role = %{role | model: chosen_model, system_prompt: meta_prompt}
    runner = Keyword.get(opts, :runner, &default_runner/3)

    try do
      case runner.(temp_cwd, improver_role, opts) do
        {:ok, stdout, usage} ->
          Rail.Roles.parse_proposal(stdout, role.id, chosen_model, role.system_prompt, sources, usage)

        {:ok, stdout} ->
          Rail.Roles.parse_proposal(stdout, role.id, chosen_model, role.system_prompt, sources, %{})

        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm_rf(temp_cwd)
    end
  end

  defp default_runner(temp_cwd, improver_role, _opts) do
    args =
      Runs.build_args(
        backend: improver_role.cli_backend,
        model: improver_role.model,
        prompt: improver_role.system_prompt,
        read_only: true,
        work_dir: temp_cwd
      )

    exe = Probes.configured_path(improver_role.cli_backend)

    case Tools.run(exe, args, cd: temp_cwd, stderr_to_stdout: true) do
      {stdout, 0} ->
        {:ok, stdout, %{}}

      {output, exit_code} ->
        msg =
          if is_binary(output) and String.trim(output) != "" do
            String.trim(output)
          else
            "CLI exited with code #{exit_code}"
          end

        {:error, {:run_failed, msg}}
    end
  end
end
