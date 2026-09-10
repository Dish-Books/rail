defmodule Rail.Roles.RoleRunRecord do
  @moduledoc """
  Historical execution record and transcript digest for a role run.
  """

  @enforce_keys [:task_id, :title, :stage, :status, :transcript_text]
  defstruct [
    :task_id,
    :title,
    :stage,
    :status,
    :exit_code,
    :duration,
    :usage,
    :error,
    :transcript_text,
    :completed_at
  ]
end
