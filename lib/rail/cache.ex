defmodule Rail.Cache do
  @moduledoc """
  Application-wide cache backed by Nebulex's generational local (ETS) adapter.

  Entries survive the processes that write them, so caches populated from a
  LiveView are not lost when the page closes. Use the `Nebulex.Caching`
  decorators (`cacheable`, `cache_put`, `cache_evict`) to cache function
  results rather than reading and writing keys by hand.
  """
  use Nebulex.Cache, otp_app: :rail, adapter: Nebulex.Adapters.Local
end
