defmodule RailCredo.Checks.LiveViewHandleParamsTest do
  use Credo.Test.Case, async: true

  alias RailCredo.Checks.LiveViewHandleParams

  test "allows LiveView with handle_params/3 defined" do
    """
    defmodule RailWeb.Live.Some.Page do
      use RailWeb, :live_view

      def mount(_params, _session, socket), do: {:ok, socket}

      def handle_params(_params, _uri, socket), do: {:noreply, socket}

      def render(assigns), do: ~H""
    end
    """
    |> to_source_file("lib/rail_web/live/some/page.ex")
    |> run_check(LiveViewHandleParams)
    |> refute_issues()
  end

  test "allows handle_params/3 with a guard clause" do
    """
    defmodule RailWeb.Live.Some.Page do
      use RailWeb, :live_view

      def handle_params(params, _uri, socket) when is_map(params) do
        {:noreply, socket}
      end
    end
    """
    |> to_source_file("lib/rail_web/live/some/page.ex")
    |> run_check(LiveViewHandleParams)
    |> refute_issues()
  end

  test "ignores non-LiveView modules" do
    """
    defmodule Rail.Banks.Schemas.BankConnection do
      def some_unrelated_function, do: :ok
    end
    """
    |> to_source_file("lib/rail/banks/schemas/bank_connection.ex")
    |> run_check(LiveViewHandleParams)
    |> refute_issues()
  end

  test "ignores ConnCase test files" do
    """
    defmodule RailWeb.Live.Some.PageTest do
      use RailWeb.ConnCase, async: true

      def some_helper, do: :ok
    end
    """
    |> to_source_file("lib/rail_web/live/some/page_test.ex")
    |> run_check(LiveViewHandleParams)
    |> refute_issues()
  end

  test "skips hook modules under RailWeb.Hooks.*" do
    # Hooks use `:live_view` to bring in helpers (e.g. date_picker.ex) but
    # Phoenix only calls handle_params/3 on the actual LiveView, never on
    # attached hooks, so requiring it on hooks would just be dead code.
    """
    defmodule RailWeb.Hooks.SomeHook do
      use RailWeb, :live_view

      def on_mount(:default, _params, _session, socket), do: {:cont, socket}
    end
    """
    |> to_source_file("lib/rail_web/hooks/some_hook.ex")
    |> run_check(LiveViewHandleParams)
    |> refute_issues()
  end

  test "skips util modules under RailWeb.Utils.*" do
    # Utils use `:live_view` only to bring in helpers like assign/2 - they're
    # never mounted as a LiveView, so handle_params/3 is dead code on them.
    """
    defmodule RailWeb.Utils.SomeHelper do
      use RailWeb, :live_view

      def some_helper(socket), do: socket
    end
    """
    |> to_source_file("lib/rail_web/utils/some_helper.ex")
    |> run_check(LiveViewHandleParams)
    |> refute_issues()
  end

  test "skips .exs files" do
    """
    defmodule RailWeb.Live.Some.PageTest do
      use RailWeb, :live_view
    end
    """
    |> to_source_file("lib/rail_web/live/some/page_test.exs")
    |> run_check(LiveViewHandleParams)
    |> refute_issues()
  end

  test "flags LiveView missing handle_params/3" do
    """
    defmodule RailWeb.Live.Accounting.Reports.CashFlow do
      use RailWeb, :live_view

      on_mount RailWeb.Hooks.DatePicker

      def mount(_params, _session, socket), do: {:ok, socket}

      def render(assigns), do: ~H""
    end
    """
    |> to_source_file("lib/rail_web/live/accounting/reports/cash_flow.ex")
    |> run_check(LiveViewHandleParams)
    |> assert_issue(fn issue ->
      assert issue.trigger == "handle_params/3"
      assert issue.message =~ "handle_params/3"
    end)
  end

  test "flags LiveView missing handle_params/3 when a later `use` follows `:live_view`" do
    # Regression: detection must not be reset by a `use` that comes after the
    # `use RailWeb, :live_view` line (e.g. `use LiveSync, ...`).
    """
    defmodule RailWeb.Live.Settings.Roles do
      use RailWeb, :live_view
      use LiveSync, subscription_key: :organization_id, watch: [:roles]

      def mount(_params, _session, socket), do: {:ok, socket}

      def render(assigns), do: ~H""
    end
    """
    |> to_source_file("lib/rail_web/live/settings/roles.ex")
    |> run_check(LiveViewHandleParams)
    |> assert_issue(fn issue ->
      assert issue.trigger == "handle_params/3"
    end)
  end

  test "allows LiveView with handle_params/3 when a later `use` follows `:live_view`" do
    """
    defmodule RailWeb.Live.Settings.Roles do
      use RailWeb, :live_view
      use LiveSync, subscription_key: :organization_id, watch: [:roles]

      def handle_params(_params, _uri, socket), do: {:noreply, socket}
    end
    """
    |> to_source_file("lib/rail_web/live/settings/roles.ex")
    |> run_check(LiveViewHandleParams)
    |> refute_issues()
  end

  test "flags LiveView with handle_params of wrong arity" do
    """
    defmodule RailWeb.Live.Some.Page do
      use RailWeb, :live_view

      def handle_params(_params, socket), do: {:noreply, socket}
    end
    """
    |> to_source_file("lib/rail_web/live/some/page.ex")
    |> run_check(LiveViewHandleParams)
    |> assert_issue(fn issue ->
      assert issue.trigger == "handle_params/3"
    end)
  end

  test "flags plain LiveView with no callbacks at all" do
    """
    defmodule RailWeb.Live.Some.Page do
      use RailWeb, :live_view
    end
    """
    |> to_source_file("lib/rail_web/live/some/page.ex")
    |> run_check(LiveViewHandleParams)
    |> assert_issue()
  end
end
