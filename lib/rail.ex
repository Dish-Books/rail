defmodule Rail do
  @moduledoc """
  Rail's own settings, each read when asked, in one place a test can stub for
  itself without changing them for the tests beside it.
  """

  @doc "Where sandboxes run: `:local`, beside Rail, or `:docker`, which enforces what each reserves."
  def sandbox_runtime, do: sandbox(:runtime, :local)

  @doc "The image a Docker sandbox is created from."
  def sandbox_image, do: sandbox(:image, "rail-sandbox:latest")

  @doc "What a Docker sandbox has mounted, at the paths Rail sees them."
  def sandbox_binds, do: sandbox(:binds, [])

  @doc "The shared memory a Docker sandbox gets, in GB, so a headless Chrome in it has room."
  def sandbox_shm_size_gb, do: sandbox(:shm_size_gb, 1)

  @doc "The CPUs kept back from sandboxes for Rail, Postgres and project services."
  def sandbox_headroom_cpus, do: sandbox(:headroom_cpus, 0)

  @doc "The memory kept back from sandboxes for Rail, Postgres and project services, in GB."
  def sandbox_headroom_memory_gb, do: sandbox(:headroom_memory_gb, 0)

  @doc "The CPUs the local runtime is fixed to, or nil to read the machine's."
  def local_cpus, do: sandbox(:local_cpus, nil)

  @doc "The memory the local runtime is fixed to, in GB, or nil to read the machine's."
  def local_memory_gb, do: sandbox(:local_memory_gb, nil)

  @doc "Where the shared browser keeps its profile, and the address Chrome writes into it."
  def browser_root, do: browser(:root, nil) || Path.join([System.tmp_dir!(), "rail", "browser"])

  @doc "The CPUs the shared browser's container is given, and kept back from the sandbox line."
  def browser_cpus, do: browser(:cpus, 2)

  @doc "The memory the shared browser's container is given, in GB, and kept back from the sandbox line."
  def browser_memory_gb, do: browser(:memory_gb, 4)

  @doc "The shared memory the browser's container gets, in GB; Chrome renders every tab through it."
  def browser_shm_size_gb, do: browser(:shm_size_gb, 2)

  @doc "Whether Rail adopts in-flight processes as it boots."
  def adopt_on_boot?, do: Application.get_env(:rail, :adopt_on_boot, true)

  defp browser(key, default), do: :rail |> Application.get_env(:browser, []) |> Keyword.get(key, default)

  defp sandbox(key, default), do: :rail |> Application.get_env(:sandbox, []) |> Keyword.get(key, default)
end
