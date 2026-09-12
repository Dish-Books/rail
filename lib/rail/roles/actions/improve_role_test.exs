defmodule Rail.Roles.Actions.ImproveRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.RoleInstructionProposal
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Scope

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Improve Role Project",
        github_repo: "org/improve-role",
        github_installation_id: 4502,
        linear_team_id: "team_improve_role",
        linear_team_key: "IMP",
        default_branch: "main",
        clone_path: "/tmp/repos/improve-role"
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        name: "Engineer",
        stage: :engineer,
        backend_id: backend.id,
        model: "claude-3-7-sonnet",
        system_prompt: "Old prompt"
      })

    %{project: project, role: role}
  end

  # The role carries its backend, so pointing the backend at a stub means reloading
  # the role too.
  defp configure_claude(role, executable_path) do
    {:ok, backend} = Roles.get_role(id: role.id)
    {:ok, _updated} = Rail.Backends.update_backend(system_scope(), backend.backend, %{executable_path: executable_path})
    {:ok, reloaded} = Roles.get_role(id: role.id)
    reloaded
  end

  test "returns not authorized when user is not admin", %{role: role} do
    scope = Scope.for_user(%{admin: false})

    assert {:error, :not_authorized} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet")

    assert {:error, :not_authorized} =
             Roles.improve_role(nil, role, "claude-3-7-sonnet")
  end

  test "returns no_evidence when role has no finished runs", %{role: role} do
    scope = Scope.for_user(%{admin: true})

    assert {:error, :no_evidence} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet")
  end

  test "runs improvement with custom runner and cleans up temp directory", %{role: %Role{id: role_id} = role} do
    scope = Scope.for_user(%{admin: true})

    {:ok, run} =
      Runs.create_run(%{
        task_id: "tsk_improve_role",
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Previous run output")

    test_pid = self()

    mock_runner = fn temp_cwd, improver_role, _opts ->
      send(test_pid, {:temp_cwd, temp_cwd})
      assert improver_role.model == "claude-3-7-sonnet"
      assert improver_role.system_prompt =~ "You are an expert prompt engineer"

      output = """
      Rationale here.
      <<<INSTRUCTIONS>>>
      New improved prompt.
      <<<END INSTRUCTIONS>>>
      After rationale.
      """

      {:ok, output, %{"input_tokens" => 500}}
    end

    assert {:ok, %RoleInstructionProposal{role_id: ^role_id, proposed: "New improved prompt.", current: "Old prompt"}} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet", runner: mock_runner)

    assert_received {:temp_cwd, captured_cwd}
    refute File.exists?(captured_cwd)
  end

  test "handles runner returning 2-element {:ok, stdout}", %{role: role} do
    scope = Scope.for_system()

    {:ok, run} =
      Runs.create_run(%{
        task_id: "tsk_improve_role",
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Previous run output")

    runner = fn _dir, _role, _opts ->
      output = """
      <<<INSTRUCTIONS>>>
      Revised prompt only.
      <<<END INSTRUCTIONS>>>
      """

      {:ok, output}
    end

    assert {:ok, %RoleInstructionProposal{proposed: "Revised prompt only."}} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet", runner: runner)
  end

  test "handles runner failure and cleans up temp directory", %{role: role} do
    scope = Scope.for_user(%{admin: true})

    {:ok, run} =
      Runs.create_run(%{
        task_id: "tsk_improve_role",
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Previous run output")

    test_pid = self()

    failing_runner = fn temp_cwd, _role, _opts ->
      send(test_pid, {:temp_cwd, temp_cwd})
      {:error, {:run_failed, "Process killed"}}
    end

    assert {:error, {:run_failed, "Process killed"}} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet", runner: failing_runner)

    assert_received {:temp_cwd, captured_cwd}
    refute File.exists?(captured_cwd)
  end

  test "cleans up temp directory even if runner raises", %{role: role} do
    scope = Scope.for_user(%{admin: true})

    {:ok, run} =
      Runs.create_run(%{
        task_id: "tsk_improve_role",
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Previous run output")

    test_pid = self()

    exploding_runner = fn temp_cwd, _role, _opts ->
      send(test_pid, {:temp_cwd, temp_cwd})
      raise "Unexpected crash"
    end

    assert_raise RuntimeError, "Unexpected crash", fn ->
      Roles.improve_role(scope, role, "claude-3-7-sonnet", runner: exploding_runner)
    end

    assert_received {:temp_cwd, captured_cwd}
    refute File.exists?(captured_cwd)
  end

  test "executes default runner when no custom runner is provided", %{role: role} do
    scope = Scope.for_system()

    {:ok, run} =
      Runs.create_run(%{
        task_id: "tsk_improve_role",
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Previous run output")

    script_path = Path.join(System.tmp_dir!(), "mock_claude_#{System.unique_integer([:positive])}.sh")

    File.write!(script_path, """
    #!/bin/sh
    cat <<'EOF'
    Analysis of previous runs.
    <<<INSTRUCTIONS>>>
    Echoed prompt
    <<<END INSTRUCTIONS>>>
    EOF
    """)

    File.chmod!(script_path, 0o755)

    on_exit(fn ->
      File.rm(script_path)
    end)

    role = configure_claude(role, script_path)

    assert {:ok, %RoleInstructionProposal{proposed: "Echoed prompt"}} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet")
  end

  test "handles default runner non-zero exit", %{role: role} do
    scope = Scope.for_system()

    {:ok, run} =
      Runs.create_run(%{
        task_id: "tsk_improve_role",
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Previous run output")

    # Use /usr/bin/false to simulate CLI failure
    role = configure_claude(role, "/usr/bin/false")

    assert {:error, {:run_failed, msg}} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet")

    assert msg =~ "CLI exited with code 1"
  end

  test "handles default runner non-zero exit with stderr message", %{role: role} do
    scope = Scope.for_system()

    {:ok, run} =
      Runs.create_run(%{
        task_id: "tsk_improve_role",
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Previous run output")

    script_path = Path.join(System.tmp_dir!(), "mock_claude_err_#{System.unique_integer([:positive])}.sh")

    File.write!(script_path, """
    #!/bin/sh
    echo "something broke in runner" >&2
    exit 2
    """)

    File.chmod!(script_path, 0o755)

    on_exit(fn ->
      File.rm(script_path)
    end)

    role = configure_claude(role, script_path)

    expected_msg = "something broke in runner"

    assert {:error, {:run_failed, ^expected_msg}} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet")
  end
end
