defmodule RailTest.Helpers do
  @moduledoc false

  alias Rail.Scope

  defdelegate user_scope(attrs \\ []), to: Scope
  defdelegate temp_user_scope(attrs \\ []), to: Scope
  defdelegate system_scope, to: Scope
  defdelegate create_temp_git_repo(opts \\ []), to: RailTest.GitHelpers
  defdelegate git!(dir, args), to: RailTest.GitHelpers
  defdelegate create_test_project(attrs \\ %{}), to: RailTest.RolesHelpers
  defdelegate create_test_role(attrs \\ %{}), to: RailTest.RolesHelpers
  defdelegate create_test_role_run(attrs \\ %{}), to: RailTest.RolesHelpers
  defdelegate create_test_run(attrs \\ %{}), to: RailTest.RolesHelpers
  defdelegate create_test_run_event(attrs \\ %{}), to: RailTest.RolesHelpers
  defdelegate create_test_task(attrs \\ %{}), to: RailTest.PipelineHelpers
  defdelegate create_test_question(attrs \\ %{}), to: RailTest.PipelineHelpers
  defdelegate create_test_plan(attrs \\ %{}), to: RailTest.PipelineHelpers
  defdelegate create_test_issue(attrs \\ %{}), to: RailTest.PipelineHelpers
  defdelegate create_test_design(attrs \\ %{}), to: RailTest.PipelineHelpers
  defdelegate create_test_linear_workspace(attrs \\ %{}), to: RailTest.PipelineHelpers
  defdelegate create_temp_scratch_dir, to: RailTest.PipelineHelpers
  defdelegate create_test_design_dir(opts \\ []), to: RailTest.PipelineHelpers
  defdelegate mock_design_uploads(count \\ 1), to: RailTest.PipelineHelpers
  defdelegate create_test_demo(attrs \\ %{}), to: RailTest.PipelineHelpers
  defdelegate create_test_demo_dir(opts \\ []), to: RailTest.PipelineHelpers
  defdelegate mock_demo_uploads(count \\ 1), to: RailTest.PipelineHelpers
  defdelegate create_test_qa_dir(opts \\ []), to: RailTest.PipelineHelpers
  defdelegate mock_qa_uploads(count \\ 1), to: RailTest.PipelineHelpers
  defdelegate mock_dispatch_hook(task, role), to: RailTest.PipelineHelpers
  defdelegate create_chat_stub_cli(opts \\ []), to: RailTest.PipelineHelpers

  def wait_until_ticks_clear(server, timeout_ms \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_ticks_clear(server, deadline)
  end

  defp do_wait_ticks_clear(server, deadline) do
    case GenServer.call(server, :running_ticks) do
      [] ->
        :ok

      _other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_wait_ticks_clear(server, deadline)
        else
          :timeout
        end
    end
  end
end
