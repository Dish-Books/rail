defmodule Rail.Roles.Actions.ImproveRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.RoleInstructionProposal
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "returns not authorized when user is not admin" do
    scope = Scope.for_user(%{admin: false})
    role = create_test_role()

    assert {:error, :not_authorized} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet")

    assert {:error, :not_authorized} =
             Roles.improve_role(nil, role, "claude-3-7-sonnet")
  end

  test "returns no_evidence when role has no finished runs" do
    scope = Scope.for_user(%{admin: true})
    role = create_test_role()

    assert {:error, :no_evidence} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet")
  end

  test "runs improvement with custom runner and cleans up temp directory" do
    scope = Scope.for_user(%{admin: true})
    %Role{id: role_id} = role = create_test_role(system_prompt: "Old prompt")

    create_test_role_run(
      role_id: role.id,
      status: :finished,
      output: "Previous run output"
    )

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

  test "handles runner returning 2-element {:ok, stdout}" do
    scope = Scope.for_system()
    role = create_test_role()

    create_test_role_run(role_id: role.id, status: :finished, output: "Output")

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

  test "handles runner failure and cleans up temp directory" do
    scope = Scope.for_user(%{admin: true})
    role = create_test_role()

    create_test_role_run(role_id: role.id, status: :finished, output: "Output")

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

  test "cleans up temp directory even if runner raises" do
    scope = Scope.for_user(%{admin: true})
    role = create_test_role()

    create_test_role_run(role_id: role.id, status: :finished, output: "Output")

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

  test "executes default runner when no custom runner is provided" do
    scope = Scope.for_system()
    role = create_test_role(cli_backend: :claude)

    create_test_role_run(role_id: role.id, status: :finished, output: "Output")

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

    assert {:ok, %RoleInstructionProposal{proposed: "Echoed prompt"}} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet", claude_path: script_path)
  end

  test "handles default runner non-zero exit" do
    scope = Scope.for_system()
    role = create_test_role(cli_backend: :claude)

    create_test_role_run(role_id: role.id, status: :finished, output: "Output")

    # Use /usr/bin/false to simulate CLI failure
    assert {:error, {:run_failed, msg}} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet", claude_path: "/usr/bin/false")

    assert msg =~ "CLI exited with code 1"
  end

  test "handles default runner non-zero exit with stderr message" do
    scope = Scope.for_system()
    role = create_test_role(cli_backend: :claude)

    create_test_role_run(role_id: role.id, status: :finished, output: "Output")

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

    expected_msg = "something broke in runner"

    assert {:error, {:run_failed, ^expected_msg}} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet", claude_path: script_path)
  end
end
