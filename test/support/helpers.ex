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
  defdelegate create_temp_scratch_dir, to: RailTest.PipelineHelpers
  defdelegate mock_dispatch_hook(task, role), to: RailTest.PipelineHelpers
  defdelegate create_chat_stub_cli(opts \\ []), to: RailTest.PipelineHelpers
end
