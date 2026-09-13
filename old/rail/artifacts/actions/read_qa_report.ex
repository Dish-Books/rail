defmodule Rail.Artifacts.Actions.ReadQaReport do
  @moduledoc false

  alias Rail.Artifacts.Validators.QaValidator

  @doc """
  Reads the qa manifest the agent wrote into `scratch_dir`.

  `scratch_dir` is the task's scratch directory; the manifest belongs at
  `qa/manifest.json` under it and nowhere else.
  """
  def read_qa_report(_scope, scratch_dir, opts \\ []) when is_binary(scratch_dir) do
    scratch_dir
    |> Path.join("qa")
    |> QaValidator.validate(opts)
  end
end
