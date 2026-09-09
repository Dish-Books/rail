defmodule RailCredo.Checks.ActionAndUtilAccessTest do
  use Credo.Test.Case, async: true

  alias RailCredo.Checks.ActionAndUtilAccess

  test "allows aliasing the Actions namespace itself" do
    """
    defmodule Rail.Foo do
      alias Rail.Banks.Actions
    end
    """
    |> to_source_file("lib/rail/foo.ex")
    |> run_check(ActionAndUtilAccess)
    |> refute_issues()
  end

  test "allows aliasing the Utils namespace itself" do
    """
    defmodule RailWeb.Helpers do
      alias RailWeb.Utils
    end
    """
    |> to_source_file("lib/rail_web/helpers.ex")
    |> run_check(ActionAndUtilAccess)
    |> refute_issues()
  end

  test "allows aliases unrelated to Actions or Utils" do
    """
    defmodule Rail.Foo do
      alias Rail.Banks.Schemas.BankConnection
      alias Rail.Repo
    end
    """
    |> to_source_file("lib/rail/foo.ex")
    |> run_check(ActionAndUtilAccess)
    |> refute_issues()
  end

  test "flags an alias of a leaf Action module" do
    """
    defmodule Rail.Foo do
      alias Rail.Banks.Actions.CreateBankConnection
    end
    """
    |> to_source_file("lib/rail/foo.ex")
    |> run_check(ActionAndUtilAccess)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Rail.Banks.Actions.CreateBankConnection"
      assert issue.message =~ "context"
    end)
  end

  test "flags an alias of a leaf Util module with import guidance" do
    """
    defmodule Rail.Foo do
      alias Rail.Billing.Utils.CalculatePlanTotal
    end
    """
    |> to_source_file("lib/rail/foo.ex")
    |> run_check(ActionAndUtilAccess)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Rail.Billing.Utils.CalculatePlanTotal"
      assert issue.message =~ "import"
    end)
  end

  test "flags an Action alias inside a .exs test file" do
    """
    defmodule Rail.Shared.Actions.SumDecimalsTest do
      alias Rail.Shared.Actions.SumDecimals
    end
    """
    |> to_source_file("lib/rail/shared/actions/sum_decimals_test.exs")
    |> run_check(ActionAndUtilAccess)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Rail.Shared.Actions.SumDecimals"
    end)
  end

  test "flags an alias when Actions appears mid-path with submodule" do
    """
    defmodule Rail.Foo do
      alias Rail.Banks.Actions.CreateBankConnection.Inner
    end
    """
    |> to_source_file("lib/rail/foo.ex")
    |> run_check(ActionAndUtilAccess)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Rail.Banks.Actions.CreateBankConnection.Inner"
    end)
  end

  test "flags both Actions and Utils aliases in the same file" do
    """
    defmodule Rail.Foo do
      alias Rail.Banks.Actions.CreateBankConnection
      alias Rail.Billing.Utils.CalculatePlanTotal
    end
    """
    |> to_source_file("lib/rail/foo.ex")
    |> run_check(ActionAndUtilAccess)
    |> assert_issues(fn issues ->
      assert length(issues) == 2
    end)
  end

  test "allows importing a leaf Util module" do
    """
    defmodule Rail.Banks.Actions.SyncTransaction do
      import Rail.Banks.Utils.FormatTransaction
    end
    """
    |> to_source_file("lib/rail/banks/actions/sync_transaction.ex")
    |> run_check(ActionAndUtilAccess)
    |> refute_issues()
  end

  test "flags importing a leaf Action module" do
    """
    defmodule Rail.Sales.Actions.DeletePayment do
      import Rail.Sales.Actions.UpdateInvoice
    end
    """
    |> to_source_file("lib/rail/sales/actions/delete_payment.ex")
    |> run_check(ActionAndUtilAccess)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Rail.Sales.Actions.UpdateInvoice"
      assert issue.message =~ "context module"
    end)
  end

  test "flags importing an Action from a test file" do
    """
    defmodule Rail.Sales.Actions.RepollTest do
      import Rail.Integrations.Actions.ImportObject
    end
    """
    |> to_source_file("lib/rail/sales/actions/repoll_test.exs")
    |> run_check(ActionAndUtilAccess)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Rail.Integrations.Actions.ImportObject"
    end)
  end

  test "flags calling an Action by its full name" do
    """
    defmodule Rail.Foo do
      def run(scope, attrs) do
        Rail.Banks.Actions.CreateBankConnection.create_bank_connection(scope, attrs)
      end
    end
    """
    |> to_source_file("lib/rail/foo.ex")
    |> run_check(ActionAndUtilAccess)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Rail.Banks.Actions.CreateBankConnection"
      assert issue.message =~ "context module"
    end)
  end

  test "flags calling a Util by its full name" do
    """
    defmodule Rail.Foo do
      def run(plan) do
        Rail.Billing.Utils.CalculatePlanTotal.calculate_plan_total(plan)
      end
    end
    """
    |> to_source_file("lib/rail/foo.ex")
    |> run_check(ActionAndUtilAccess)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Rail.Billing.Utils.CalculatePlanTotal"
      assert issue.message =~ "import"
    end)
  end

  test "allows a context defdelegate pointing at an action module" do
    """
    defmodule Rail.Banks do
      alias Rail.Banks.Actions

      defdelegate create_bank_connection(scope, attrs), to: Actions.CreateBankConnection
    end
    """
    |> to_source_file("lib/rail/banks.ex")
    |> run_check(ActionAndUtilAccess)
    |> refute_issues()
  end

  test "allows a fully-qualified call to a context module" do
    """
    defmodule Rail.Foo do
      def run(scope, bill) do
        Rail.Expenses.delete_bill(scope, bill)
      end
    end
    """
    |> to_source_file("lib/rail/foo.ex")
    |> run_check(ActionAndUtilAccess)
    |> refute_issues()
  end

  test "flags each module in a grouped alias of Action modules" do
    """
    defmodule Rail.Foo do
      alias Rail.Banks.Actions.{CreateBankConnection, DeleteBankConnection}
    end
    """
    |> to_source_file("lib/rail/foo.ex")
    |> run_check(ActionAndUtilAccess)
    |> assert_issues(fn issues ->
      assert length(issues) == 2
    end)
  end
end
