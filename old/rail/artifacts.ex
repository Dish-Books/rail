defmodule Rail.Artifacts do
  @moduledoc """
  Context for visual and test artifacts produced by agent roles, including
  demo walkthroughs, manifest validation,
  Linear storage, scratch materialization, and asset proxying.
  """

  use Rail.PermissionsDecorator

  alias Rail.Artifacts.Actions

  @decorate can?(resource: :artifacts, action: :view)
  defdelegate read_demo(scope, target, opts \\ []), to: Actions.ReadDemo

  @decorate can?(resource: :artifacts, action: :manage)
  defdelegate capture_demo(scope, target, scratch_dir_or_opts, opts \\ []), to: Actions.CaptureDemo

  defdelegate latest_demo(task), to: Actions.LatestDemo

  @decorate can?(resource: :artifacts, action: :manage)
  defdelegate mark_demo_stale(scope, target, opts \\ []), to: Actions.MarkDemoStale

  @decorate can?(resource: :artifacts, action: :manage)
  defdelegate materialize(scope, target, dest_scratch_dir, opts \\ []), to: Actions.Materialize

  defdelegate asset_url(kind, id), to: Actions.AssetUrl

  @decorate can?(resource: :artifacts, action: :view)
  defdelegate get_asset(scope, kind, id), to: Actions.GetAsset
end
