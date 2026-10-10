defmodule Rail.Tools.Actions.RetrySandboxImageCopy do
  @moduledoc false

  alias Rail.Tools.HostConnection
  alias Rail.Tools.Schemas.SandboxHost
  alias Rail.Tools.Workers.SyncSandboxImage

  @doc "Queues a failed copy again. The job is unique per host, so a second press adds none."
  def retry_sandbox_image_copy(_scope, %SandboxHost{id: host_id} = host) do
    {:ok, _job_or_conflict} = %{host_id: host_id} |> SyncSandboxImage.new() |> Oban.insert()
    HostConnection.report_image(host_id, {:copying, 0, nil})
    {:ok, host}
  end
end
