defmodule Rail.Artifacts do
  @moduledoc """
  Context for visual and test artifacts produced by agent roles, including
  design directions, demo walkthroughs, QA reports, manifest validation,
  Linear storage, scratch materialization, and asset proxying.
  """

  alias Rail.Artifacts.Actions

  defdelegate read_demo(scope, target, opts \\ []), to: Actions.ReadDemo
  defdelegate read_design(scope, target, opts \\ []), to: Actions.ReadDesign
  defdelegate read_qa_report(scope, target, opts \\ []), to: Actions.ReadQaReport

  defdelegate capture_demo(scope, target, scratch_dir_or_opts, opts \\ []), to: Actions.CaptureDemo
  defdelegate capture_design(scope, target, scratch_dir_or_opts, opts \\ []), to: Actions.CaptureDesign
  defdelegate capture_qa_report(scope, target, scratch_dir_or_opts, opts \\ []), to: Actions.CaptureQaReport

  defdelegate mark_demo_stale(scope, target, opts \\ []), to: Actions.MarkDemoStale
  defdelegate materialize(scope, target, dest_scratch_dir, opts \\ []), to: Actions.Materialize
  defdelegate asset_url(kind, id), to: Actions.AssetUrl
  defdelegate get_asset(scope, kind, id), to: Actions.GetAsset
end
