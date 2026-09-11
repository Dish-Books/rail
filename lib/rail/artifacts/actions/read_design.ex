defmodule Rail.Artifacts.Actions.ReadDesign do
  @moduledoc false

  alias Rail.Artifacts.Validators.DesignValidator

  @doc """
  Reads the design manifest the agent wrote into `scratch_dir`.

  `scratch_dir` is the task's scratch directory; the manifest belongs at
  `design/manifest.json` under it and nowhere else.
  """
  def read_design(_scope, scratch_dir, opts \\ []) when is_binary(scratch_dir) do
    scratch_dir
    |> Path.join("design")
    |> DesignValidator.validate(opts)
  end
end
