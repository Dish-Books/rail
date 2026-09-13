defmodule Rail.Artifacts.Actions.ReadDemo do
  @moduledoc false

  alias Rail.Artifacts.Validators.DemoValidator

  @doc """
  Reads the demo manifest the agent wrote into `scratch_dir`.

  `scratch_dir` is the task's scratch directory; the manifest belongs at
  `demo/manifest.json` under it and nowhere else.
  """
  def read_demo(_scope, scratch_dir, opts \\ []) when is_binary(scratch_dir) do
    scratch_dir
    |> Path.join("demo")
    |> DemoValidator.validate(opts)
  end
end
